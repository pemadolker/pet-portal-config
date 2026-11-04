#!/usr/bin/env bash
# E8 - Registry member loss. Deletes one of the three etcd members and shows that
# the registry still reads and writes (quorum 2 of 3), the gateway keeps routing,
# and the member rejoins when the StatefulSet recreates it.
set -euo pipefail
VICTIM=${1:-registry-etcd-1}; ENV=${2:-prod}
e() { kubectl -n registry exec registry-etcd-0 -- etcdctl "$@"; }
EP=http://registry-etcd-0.registry-etcd.registry.svc:2379,http://registry-etcd-1.registry-etcd.registry.svc:2379,http://registry-etcd-2.registry-etcd.registry.svc:2379
echo "== before"; e --endpoints=$EP endpoint health --cluster 2>&1 || true; e member list -w table
echo "== deleting $VICTIM"; kubectl -n registry delete pod "$VICTIM" --wait=false
sleep 3
echo "== during: health, write, read"
e --endpoints=$EP endpoint health --cluster 2>&1 || true
e put /pet-portal/$ENV/e8-probe "written while $VICTIM was down at $(date +%T)"
e get /pet-portal/$ENV/e8-probe
echo "registered $ENV services: $(e get --prefix /pet-portal/$ENV/services/ --keys-only | grep -c services || true)"
echo "== gateway still routing (through the ingress)"
HOST=$([[ $ENV == prod ]] && echo portal.local || echo dev.portal.local)
for i in 1 2 3 4 5; do curl -sk -o /dev/null -w "  GET /api/search -> %{http_code}\n" "https://$HOST/api/search?limit=1"; sleep 1; done
echo "== waiting for $VICTIM to rejoin"
kubectl -n registry wait --for=condition=Ready "pod/$VICTIM" --timeout=180s
e --endpoints=$EP endpoint health --cluster; e member list -w table
e del /pet-portal/$ENV/e8-probe >/dev/null
echo "E8 PASS if every write/read above succeeded, every GET returned 200, and all 3 members are healthy again."
