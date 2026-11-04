#!/usr/bin/env bash
# E9 - Network isolation. From a test pod, tries the paths that must be blocked
# (straight to PostgreSQL, straight to a backend service, straight to the gateway
# from outside the ingress controller) and the one that must work (through the Ingress).
# Pass: forbidden paths time out; the allowed path returns 200.
set -uo pipefail
ENV=${1:-prod}; NS=pet-portal-$ENV
HOST=$([[ $ENV == prod ]] && echo portal.local || echo dev.portal.local)
INGRESS_IP=$(kubectl -n ingress-nginx get pod -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].status.hostIP}')
pass=0; fail=0
probe() { # namespace description expect(blocked|ok) command...
  local ns=$1 what=$2 expect=$3; shift 3
  out=$(kubectl -n "$ns" run "e9-$RANDOM" --rm -i --restart=Never --quiet --image=curlimages/curl:8.11.1 \
        --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"c","image":"curlimages/curl:8.11.1","command":["sh","-c","'"$*"'"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' 2>&1)
  code=$(echo "$out" | tail -1)
  if [[ $expect == blocked && $code == 000 ]] || [[ $expect == ok && $code == 200 ]]; then r=PASS; pass=$((pass+1)); else r=FAIL; fail=$((fail+1)); fi
  printf '%-4s %-62s expected %-7s got %s\n' "$r" "$what" "$expect" "$code"
}
C="curl -s -o /dev/null -w %{http_code} --max-time 5"
probe "$NS" "pod in $NS -> postgres:5432"                 blocked "$C telnet://postgres:5432 || echo 000"
probe "$NS" "pod in $NS -> adoption:8080 (skip the gateway)" blocked "$C http://adoption:8080/adoptions/mine || echo 000"
probe default "pod in default -> adoption.$NS:8080"        blocked "$C http://adoption.$NS.svc:8080/health || echo 000"
probe default "pod in default -> api-gateway.$NS:8080"     blocked "$C http://api-gateway.$NS.svc:8080/health || echo 000"
probe default "pod in default -> redis.$NS:6379"           blocked "$C telnet://redis.$NS.svc:6379 || echo 000"
probe default "pod in default -> https://$HOST/api (Ingress)" ok    "$C -k --resolve $HOST:443:$INGRESS_IP https://$HOST/api/search?limit=1 || echo 000"
echo "E9: $pass passed, $fail failed"; [[ $fail -eq 0 ]]
