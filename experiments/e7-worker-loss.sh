#!/usr/bin/env bash
# E7 - Worker loss. Drains one worker under load and shows where everything went.
# Picks a worker that does not hold prod's PostgreSQL or Redis (their local-path
# volumes cannot move; see the capacity plan). Uncordons it at the end.
set -euo pipefail
NS=pet-portal-${ENV:-prod}
pinned=$(kubectl -n $NS get pod postgres-0 redis-0 -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u)
NODE=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name | sed 's#node/##' | grep -vxF "$pinned" | head -1)
[[ -n "$NODE" ]] || { echo "every worker holds a data store; nothing safe to drain"; exit 1; }
echo "Draining $NODE at $(date +%T). Pods on it:"
kubectl get pods -A -o wide --field-selector spec.nodeName="$NODE" | grep -E "pet-portal|registry" || true
START=$(date +%s)
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=300s
echo "Drained in $(( $(date +%s) - START )) s. Waiting for every prod deployment to be fully ready again..."
for d in $(kubectl -n $NS get deploy -o name); do kubectl -n $NS rollout status "$d" --timeout=300s >/dev/null && echo "  ready: $d"; done
echo "All prod deployments ready $(( $(date +%s) - START )) s after the drain started."
kubectl -n registry get pods -o wide
read -r -p "Press Enter to uncordon $NODE " _ || true
kubectl uncordon "$NODE"
