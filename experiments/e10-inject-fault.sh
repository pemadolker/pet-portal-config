#!/usr/bin/env bash
# E10 - Find a fault from telemetry. One team member runs this (without saying
# which fault); another starts a timer and must find the cause from dashboards,
# traces and logs in under 10 minutes.
#   experiments/e10-inject-fault.sh lock   [minutes]   # holds a lock on pet's table: pet requests hang, then fail
#   experiments/e10-inject-fault.sh shelter [minutes]  # stops shelter: writes that check shelters fail
# Expected trail: alert (ServiceHighLatency / ServiceHighErrorRate) -> "Service overview"
# dashboard -> slow/failed trace in "Logs and traces" -> the span and log line naming the cause.
set -euo pipefail
FAULT=${1:?lock|shelter}; MIN=${2:-6}; NS=pet-portal-${ENV:-prod}
echo "Fault '$FAULT' for $MIN minutes in $NS, starting $(date +%T). Start the timer now."
case $FAULT in
  lock)
    kubectl -n $NS exec -i postgres-0 -c postgres -- psql -U postgres -d petportal -v ON_ERROR_STOP=1 <<SQL
BEGIN;
LOCK TABLE pet.pets IN ACCESS EXCLUSIVE MODE;
SELECT pg_sleep($MIN * 60);
ROLLBACK;
SQL
    ;;
  shelter)
    # prod is not auto-synced, so Argo CD shows the change as drift but does not undo it.
    kubectl -n $NS scale deploy shelter --replicas=0
    sleep $((MIN * 60))
    kubectl -n $NS scale deploy shelter --replicas=1
    ;;
  *) echo "unknown fault"; exit 1 ;;
esac
echo "Fault removed at $(date +%T)."
