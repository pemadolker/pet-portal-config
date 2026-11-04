#!/usr/bin/env bash
# E4 - Email worker scaling. Puts N emails on email.queue at once (default 500),
# far faster than one worker sends them (5 per second per pod, like a provider limit).
# Pass: email-worker pods rise above 1 (up to 4), the backlog drains to 0, and Mailpit
# holds exactly one email per queued message.
#   experiments/e4-email-burst.sh 500 prod
set -euo pipefail
N=${1:-500}; ENV=${2:-prod}; NS=pet-portal-$ENV
RUN=e4-$(date +%s)
echo "Queueing $N emails (run $RUN) on email.queue in $NS"
kubectl -n $NS exec -i redis-0 -c redis -- sh -s <<SH
i=0
while [ \$i -lt $N ]; do
  id=\$(cat /proc/sys/kernel/random/uuid)
  printf 'XADD email.queue MAXLEN ~ 100000 * id %s type email.queue data %s traceparent ""\n' "\$id" \
    "'{\"id\":\"\$id\",\"type\":\"email.queue\",\"occurredAt\":\"\$(date -u +%FT%TZ)\",\"producer\":\"e4-experiment\",\"data\":{\"to\":\"$RUN-\$i@load.test\",\"subject\":\"E4 burst \$i\",\"text\":\"Load experiment $RUN\"}}'"
  i=\$((i+1))
done | redis-cli > /dev/null
redis-cli XINFO GROUPS email.queue
SH
echo
echo "Watch:  kubectl -n $NS get hpa keda-hpa-email-worker -w     (or the Autoscaling dashboard)"
echo "Count:  every 10 s until the backlog is 0"
MAILPIT_POD=$(kubectl -n $NS get pod -l app.kubernetes.io/name=mailpit -o name | head -1)
for _ in $(seq 1 90); do
  lag=$(kubectl -n $NS exec redis-0 -c redis -- redis-cli XINFO GROUPS email.queue | awk 'f{print;exit} /^lag$/{f=1}')
  pods=$(kubectl -n $NS get deploy email-worker -o jsonpath='{.status.readyReplicas}')
  got=$(kubectl -n $NS exec "$MAILPIT_POD" -- wget -qO- "http://127.0.0.1:8025/api/v1/search?query=subject:%22E4%20burst%22%20$RUN&limit=1" 2>/dev/null | sed -E 's/.*"messages_count":([0-9]+).*/\1/')
  printf '%s  lag=%-5s email-worker pods=%s  delivered=%s/%s\n' "$(date +%T)" "${lag:-?}" "${pods:-?}" "${got:-?}" "$N"
  [[ "$lag" == "0" && "$got" == "$N" ]] && { echo "E4 PASS: backlog drained and exactly $N emails delivered"; exit 0; }
  sleep 10
done
echo "E4: not finished after 15 minutes"; exit 1
