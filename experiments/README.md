# Experiments E1 to E10

Every claim in the proposal is backed by one experiment (proposal section 12). Each
section below gives the command, the pass criterion and the evidence to save for the
final report. Run them against **prod** unless stated. Save screenshots and command
output in `evidence/E<n>/` (it is git-ignored in this repo; put it in the report).

Before any load test:

```bash
export BASE_URL=https://portal.local/api K6_INSECURE_SKIP_TLS_VERIFY=true   # self-signed certificate
export ADMIN_EMAIL=admin@portal.local ADMIN_PASSWORD=...                     # bootstrap/.secrets/credentials.txt
experiments/loadtest-mode.sh on        # raise the gateway's per-IP limits (k6 is one IP); live, through etcd
# Optional, frees about 2 GB: stop dev while testing prod
kubectl -n argocd patch app root-dev --type merge -p '{"spec":{"syncPolicy":null}}'
kubectl -n pet-portal-dev scale deploy --all --replicas=0
```

After: `experiments/loadtest-mode.sh off`, and re-enable root-dev's sync policy (`kubectl apply -f argocd/root-dev.yaml`).

Results measured while building the project (outside the cluster, on a 2-vCPU machine
with the services running natively against PostgreSQL 16 and Redis 7) are in
`docs/ha-capacity-plan.md`. Replace them with your cluster numbers.

---

## E1 Deploy from Git

```bash
kind delete cluster --name pet-portal
time APP_REPO=../pet-portal-app bootstrap/bootstrap.sh
kubectl -n argocd get applications
```
**Pass:** all 15 `<service>-prod` and `<service>-dev` applications `Synced` and `Healthy`
(plus platform and add-ons). **Evidence:** the Argo CD UI screenshot and the
"Ready in N s" line.

## E2 One winner out of many contenders

```bash
k6 run experiments/k6/e2-one-winner.js                     # 2,000 adopters, 10 pets, within 60 s
kubectl -n pet-portal-prod exec postgres-0 -c postgres -- psql -U postgres -d petportal -c \
  "SELECT pet_id, count(*) FROM adoption.applications GROUP BY 1 HAVING count(*) > 1;"   # must return 0 rows
```
Setup creates 2,000 accounts first (scrypt makes this take a few minutes; that is the
password hashing doing its job). **Pass:** k6 thresholds `adoption_accepted count==10`,
`adoption_taken count==1990`, `adoption_other count==0` all green, teardown prints
`E2 PASS`, the SQL returns no rows. **Evidence:** k6 summary, SQL output, the
"Adoption rush" dashboard during the run.

Also in CI: every push runs the same race with 300 adopters (`tests/load/one-winner.mjs` in pet-portal-app).

## E3 Adoption autoscaling

1. **Baseline (one pod's capacity).** Pause KEDA and pin one pod:
   ```bash
   kubectl -n pet-portal-prod annotate scaledobject adoption autoscaling.keda.sh/paused-replicas="1" --overwrite
   k6 run -e PROFILE=baseline experiments/k6/e3-adoption-load.js
   ```
   Note the request rate where p95 passes 500 ms or errors start: that is one pod's capacity C.
   Set `threshold` in `apps/adoption/values-prod.yaml` to 0.7 x C (proposal section 8), commit, sync.
   Remove the pause: `kubectl -n pet-portal-prod annotate scaledobject adoption autoscaling.keda.sh/paused-replicas-`.
2. **Rush.** In one terminal `kubectl -n pet-portal-prod get hpa keda-hpa-adoption -w`, in another:
   ```bash
   k6 run -e PEAK_RPS=250 experiments/k6/e3-adoption-load.js     # ramp 1 min, hold 5 min, stop
   ```
**Pass:** replicas go up from 2 under load, never above 6, and back to 2 within about
5 minutes of the load stopping (scale-down stabilisation window). **Evidence:** the
`get hpa -w` output and the "Autoscaling" and "Adoption rush" dashboards.

## E4 Email worker scaling

```bash
experiments/e4-email-burst.sh 500 prod
```
Each worker pod sends at most 5 emails per second (like a provider's limit), so 500
emails is a backlog of about 100 s for one pod. KEDA adds one pod per 20 waiting.
**Pass:** email-worker pods rise above 1 (max 4), lag returns to 0, and the script
prints `E4 PASS` (exactly 500 delivered to Mailpit, no duplicates).
**Evidence:** script output, "Autoscaling" dashboard (email.queue panel), Mailpit inbox.

## E5 Zero-downtime release

```bash
k6 run -e DURATION=6m experiments/k6/e5-steady-load.js &      # threshold: http_req_failed rate==0
# change something visible, for example a new image tag for search, then release it
scripts/set-image-tag.sh prod <new-tag> search && git commit -am "prod: search <new-tag>" && git push
scripts/sync-prod.sh search
wait
```
**Pass:** k6 reports `http_req_failed ... rate==0` green during the rollout.
How: `maxUnavailable: 0`, readiness probes, and each pod leaves the registry and waits
5 s before it stops accepting requests (graceful shutdown in `libs/common/http.js`).
**Evidence:** k6 summary and `kubectl -n pet-portal-prod rollout history deploy/search`.

## E6 Self-heal and rollback

```bash
# Self-heal (dev is auto-synced with selfHeal)
kubectl -n pet-portal-dev delete deploy review
kubectl -n argocd get app review-dev -w          # back to Synced/Healthy within about a minute

# Bad release and rollback (prod)
scripts/set-image-tag.sh prod does-not-exist pet && git commit -am "prod: bad tag" && git push
scripts/sync-prod.sh pet                         # fails: ImagePullBackOff; old pods keep serving (maxUnavailable 0)
git revert --no-edit HEAD && git push
scripts/sync-prod.sh pet                         # Healthy again
```
**Pass:** dev restores itself; the bad prod release goes Degraded/Progressing without
an outage; the revert brings it back to Healthy. **Evidence:** Argo CD history of
`pet-prod` and `review-dev`.

## E7 Worker loss

```bash
k6 run -e DURATION=6m -e MAX_FAILED_RATE=0.01 experiments/k6/e5-steady-load.js &
experiments/e7-worker-loss.sh        # drains a worker that does not hold prod's PostgreSQL or Redis
wait
```
**Pass:** core-path success above 99 %; the one-pod services come back on another
node (record how long each took from `kubectl get events`). PodDisruptionBudgets keep
one pod of every core service and two of three etcd members up during the drain.
The script never drains the node holding prod's PostgreSQL or Redis: their local-path
volumes are tied to one node, so they would wait for it to come back. That is the
documented single point of failure (capacity plan), not something E7 claims to survive.
**Evidence:** k6 summary, pod events, "Cluster and nodes" dashboard.

## E8 Registry member loss

```bash
experiments/e8-registry-member-loss.sh registry-etcd-1 prod
```
**Pass:** reads and writes still work with 2 of 3 members, every request through the
gateway returns 200, and the member rejoins (3 healthy endpoints). The
RegistryMemberDown alert fires while it is gone. **Evidence:** script output, alert screenshot.

## E9 Network isolation

```bash
experiments/e9-network-isolation.sh prod
```
**Pass:** every "blocked" line times out (000) and the Ingress path returns 200.
**Evidence:** script output; `kubectl -n pet-portal-prod get networkpolicy`.

## E10 Find a fault from telemetry

One person runs, without telling the others which fault:
```bash
experiments/e10-inject-fault.sh lock 6        # or: shelter 6
```
plus light traffic (`k6 run -e DURATION=8m experiments/k6/e5-steady-load.js` and a few
listing edits in the website). Another person starts a timer and works only from
Grafana: alert → "3. Service overview" (which service, which route) → "7. Logs and
traces" (slow or failed trace, the span that waited, the log line with its trace id).
**Pass:** alert fired and root cause named (for `lock`: pet's queries waiting on a lock
on `pet.pets`; for `shelter`: calls from pet/adoption/signup to shelter failing, circuit
open) in under 10 minutes. **Evidence:** alert screenshot, trace screenshot, the time.
