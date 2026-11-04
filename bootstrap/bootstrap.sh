#!/usr/bin/env bash
# From nothing to a running portal on one machine (experiment E1 times this).
#
#   bootstrap/bootstrap.sh            # cluster + Argo CD + add-ons + dev + prod
#   bootstrap/bootstrap.sh --no-prod  # skip prod (saves about 2 GB while developing)
#   APP_REPO=../pet-portal-app bootstrap/bootstrap.sh
#        # also builds the 15 images and loads them into Kind (no registry needed)
#
# Steps: 1 Kind cluster  2 Calico  3 Secrets  4 Argo CD  5 add-ons (root-cluster)
#        6 dev (root-dev, auto-sync)  7 prod (root-prod, synced by scripts/sync-prod.sh)
# Before the first run: bootstrap/configure.sh <github-org>, and push this repo.
# Needs: docker, kind >= 0.30, kubectl, openssl. About 12 GB of free RAM.
set -euo pipefail
cd "$(dirname "$0")/.."
START=$(date +%s)
CALICO_VERSION=v3.33.0
PROD=true; [[ "${1:-}" == "--no-prod" ]] && PROD=false
step() { printf '\n\033[1m[%ss] %s\033[0m\n' "$(( $(date +%s) - START ))" "$*"; }

for tool in docker kind kubectl openssl; do command -v $tool >/dev/null || { echo "missing: $tool"; exit 1; }; done
if grep -rq "CHANGE-ME" argocd/root-cluster.yaml; then echo "Run bootstrap/configure.sh <github-org> first (and push)."; exit 1; fi

step "1/7 Kind cluster (1 control plane + 3 workers)"
if kind get clusters | grep -qx pet-portal; then echo "cluster exists"; else kind create cluster --config bootstrap/kind-cluster.yaml --wait 0s; fi
kubectl config use-context kind-pet-portal >/dev/null

if [[ -n "${APP_REPO:-}" ]]; then
  step "1b Building the 15 images from $APP_REPO and loading them into Kind"
  REG=$(grep -E '^  imageRegistry:' envs/dev.yaml | awk '{print $2}')
  TAG=$(grep -E '^  tag:' apps/frontend/values-dev.yaml | sed -E 's/^  tag: "?([^" ]+)"?.*/\1/')
  "$APP_REPO/scripts/build-images.sh" "$REG" "$TAG" --kind
fi

step "2/7 Calico network plugin (enforces NetworkPolicy)"
kubectl apply --server-side -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" >/dev/null
kubectl -n kube-system rollout status ds/calico-node --timeout=300s
kubectl wait --for=condition=Ready nodes --all --timeout=300s

step "3/7 Secrets (random, never in Git)"
bootstrap/secrets.sh

step "4/7 Argo CD"
kubectl apply --server-side -k bootstrap/argocd >/dev/null
kubectl -n argocd rollout status deploy/argocd-server deploy/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
kubectl apply -f argocd/projects.yaml

wait_apps() { # label-selector timeout-seconds
  local sel=$1 timeout=$2 t=0
  while true; do
    local total healthy
    total=$(kubectl -n argocd get applications -l "$sel" --no-headers 2>/dev/null | wc -l)
    healthy=$(kubectl -n argocd get applications -l "$sel" -o jsonpath='{range .items[*]}{.status.health.status}{"\n"}{end}' | grep -c '^Healthy$' || true)
    printf '\r  %s/%s healthy' "$healthy" "$total"
    [[ $total -gt 0 && $healthy -eq $total ]] && { echo; return 0; }
    (( t >= timeout )) && { echo; kubectl -n argocd get applications -l "$sel"; return 1; }
    sleep 10; t=$((t + 10))
  done
}

step "5/7 Cluster add-ons: ingress, metrics-server, Prometheus/Grafana, KEDA, Loki, Tempo, Collector, Alloy, etcd registry"
kubectl apply -f argocd/root-cluster.yaml
sleep 20
wait_apps "pet-portal.bt/layer=addon" 1200

step "6/7 dev environment (auto-sync, sync waves: platform -> 13 services -> gateway + frontend)"
kubectl apply -f argocd/root-dev.yaml
sleep 20
wait_apps "pet-portal.bt/environment=dev" 1200

if $PROD; then
  step "7/7 prod environment (manual sync = release approval)"
  kubectl apply -f argocd/root-prod.yaml
  sleep 15
  scripts/sync-prod.sh
fi

step "Ready in $(( $(date +%s) - START )) s"
cat <<EOF
Add to /etc/hosts:  127.0.0.1 portal.local dev.portal.local grafana.portal.local argocd.portal.local mail.portal.local mail.dev.portal.local
  Portal (prod)  https://portal.local
  Portal (dev)   https://dev.portal.local
  Grafana        https://grafana.portal.local
  Argo CD        https://argocd.portal.local   user admin, password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
Logins: bootstrap/.secrets/credentials.txt
EOF
