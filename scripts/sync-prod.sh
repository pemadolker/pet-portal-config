#!/usr/bin/env bash
# Releases prod: syncs the prod applications in wave order, waiting for each wave
# to be healthy. Running this IS the manual approval step (proposal section 7):
# nothing reaches prod until an operator runs it (or presses Sync in the Argo CD UI).
#
#   scripts/sync-prod.sh                 # everything that is out of sync, in order
#   scripts/sync-prod.sh adoption pet    # only these services
set -euo pipefail
NS=argocd
sync_app() {
  kubectl -n $NS patch application "$1" --type merge -p \
    "{\"operation\":{\"initiatedBy\":{\"username\":\"${USER:-operator} via sync-prod.sh\"},\"sync\":{\"revision\":\"main\",\"syncOptions\":[\"PruneLast=true\"]}}}" >/dev/null
  echo "  sync requested: $1"
}
wait_healthy() {
  for app in "$@"; do
    printf '  waiting for %s' "$app"
    for _ in $(seq 1 90); do
      s=$(kubectl -n $NS get application "$app" -o jsonpath='{.status.sync.status}/{.status.health.status}/{.status.operationState.phase}')
      [[ $s == Synced/Healthy/Succeeded ]] && { echo " ok"; continue 2; }
      [[ $s == */Failed || $s == */Error ]] && { echo " FAILED ($s)"; kubectl -n $NS get application "$app" -o jsonpath='{.status.operationState.message}'; echo; exit 1; }
      printf '.'; sleep 10
    done
    echo " timed out ($s)"; exit 1
  done
}

if [[ $# -gt 0 ]]; then
  apps=(); for s in "$@"; do apps+=("$s-prod"); done
  for a in "${apps[@]}"; do sync_app "$a"; done
  wait_healthy "${apps[@]}"; exit 0
fi

echo "Wave 0: platform (namespace, quotas, policies, PostgreSQL, Redis, Mailpit)"
sync_app platform-prod; wait_healthy platform-prod
backend=$(kubectl -n $NS get applications -l pet-portal.bt/environment=prod,pet-portal.bt/layer=service -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -v -E '^(api-gateway|frontend)-prod$')
echo "Wave 1: 13 backend services"
for a in $backend; do sync_app "$a"; done; wait_healthy $backend
echo "Wave 2: api-gateway and frontend"
sync_app api-gateway-prod; sync_app frontend-prod; wait_healthy api-gateway-prod frontend-prod
echo "prod is synced and healthy."
