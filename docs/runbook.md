# Runbook

How to start, stop, scale, release, roll back and recover the portal, and what to
do when each alert fires. Commands assume `kubectl` points at `kind-pet-portal`.

## Start, stop, status

```bash
APP_REPO=../pet-portal-app bootstrap/bootstrap.sh   # from nothing (E1)
docker stop pet-portal-control-plane pet-portal-worker pet-portal-worker2 pet-portal-worker3   # pause the whole cluster
docker start pet-portal-control-plane pet-portal-worker pet-portal-worker2 pet-portal-worker3  # resume
kind delete cluster --name pet-portal               # remove everything (data included)

kubectl -n argocd get applications                  # what Argo CD thinks
kubectl -n pet-portal-prod get pods,hpa,scaledobject
kubectl top pods -n pet-portal-prod
```

## Release

* **dev:** merge to main in pet-portal-app. CI tests, builds, scans and pushes the
  images, then commits the new tag to `apps/*/values-dev.yaml` here. Argo CD syncs dev.
* **prod:** GitHub Actions → promote (all or some services) → review and merge the PR →
  `scripts/sync-prod.sh` (or Sync in the Argo CD UI, in wave order: platform, backend, edge).
* **Config change** (scaling, env, resources): PR to `apps/<service>/values*.yaml`; CI
  runs `scripts/validate.sh`; merge; dev syncs itself; prod with `scripts/sync-prod.sh <service>`.

## Roll back

```bash
git log --oneline -- apps/pet/values-prod.yaml     # find the bad commit
git revert <commit> && git push
scripts/sync-prod.sh pet
```
Database migrations only ever add (new tables, new nullable columns), so the previous
image still works against the newer schema. Never edit an applied migration file:
`migrate.js` refuses to run if a checksum changed.

## Scale by hand

Autoscaled services are owned by KEDA; to pin one temporarily:
```bash
kubectl -n pet-portal-prod annotate scaledobject adoption autoscaling.keda.sh/paused-replicas="4" --overwrite
kubectl -n pet-portal-prod annotate scaledobject adoption autoscaling.keda.sh/paused-replicas-      # resume
```
To change limits permanently, edit `minReplicas`/`maxReplicas` in `apps/<service>/values-prod.yaml`.

## Live gateway settings (etcd, no restart)

```bash
e() { kubectl -n registry exec registry-etcd-0 -- etcdctl "$@"; }
e get --prefix /pet-portal/prod/config/
e put /pet-portal/prod/config/gateway/rate_limit_per_minute 600       # per user (or IP when logged out); default 300
e put /pet-portal/prod/config/gateway/auth_rate_limit_per_minute 30   # /login and /signup per IP; default 20
e put /pet-portal/prod/config/gateway/read_only true                  # maintenance: browsing works, changes get 503
e del /pet-portal/prod/config/gateway/read_only
e get --prefix /pet-portal/prod/services/ --keys-only                 # who is registered right now
```

## Backups and restore (PostgreSQL)

```bash
kubectl -n pet-portal-prod create job --from=cronjob/postgres-backup backup-$(date +%s)    # take one now
kubectl -n pet-portal-prod logs job/<that job>                                             # "backup written: ..."
```

Restore (stops the services first so nothing writes during the restore):
```bash
kubectl -n pet-portal-prod scale deploy --all --replicas=0
kubectl -n pet-portal-prod scale deploy mailpit --replicas=1
kubectl -n pet-portal-prod run restore --rm -it --restart=Never --image=postgres:16-alpine --overrides='
{"metadata":{"labels":{"pet-portal.bt/db-job":"true"}},
 "spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":70,"fsGroup":70,"seccompProfile":{"type":"RuntimeDefault"}},
  "volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"postgres-backups"}}],
  "containers":[{"name":"restore","image":"postgres:16-alpine","stdin":true,"tty":true,"command":["sh"],
   "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},
   "volumeMounts":[{"name":"b","mountPath":"/backups"}],
   "env":[{"name":"PGHOST","value":"postgres"},{"name":"PGUSER","value":"postgres"},
          {"name":"PGPASSWORD","valueFrom":{"secretKeyRef":{"name":"postgres-superuser","key":"password"}}}]}]}}'
#   inside the pod:  ls -lh /backups
#                    pg_restore --clean --if-exists -d petportal /backups/petportal-<stamp>.dump
scripts/sync-prod.sh            # brings every service back at its declared size
```

## Secrets

Made by `bootstrap/secrets.sh` (random, never in Git). Rotate with
`bootstrap/secrets.sh --rotate`, then `kubectl -n pet-portal-prod rollout restart deploy`
and re-run the `db-bootstrap` job (sync `platform-prod`), which resets the role passwords.
Rotating `jwt-keys` logs everyone out. For a real deployment, replace the script with
Sealed Secrets or the External Secrets Operator so Secrets can live in Git encrypted.

## Access

* Argo CD: `admin` and `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.
  Project roles: `pet-portal:developers` may sync dev only; `pet-portal:operators` may sync prod.
* Kubernetes: RoleBindings in `platform/overlays/*/rbac.yaml` bind the same two groups:
  developers `edit` in dev and `view` in prod; operators `admin` in both. To give a person
  the developer group with a client certificate: create a CSR with `O=pet-portal:developers`.

---

# Alerts

Every alert links here. First look: "3. Service overview" and "7. Logs and traces".

### ServiceHighErrorRate
More than 5 % 5xx for 5 minutes. Open "Service overview", filter the service, check
"Calls to other services by outcome" (a dependency failing?) and the error logs panel.
Click a trace id. Common causes: dependency down (circuit_open), database (PostgresDown),
bad release (roll back).

### ServiceHighLatency
p95 above 500 ms. "Slowest routes" panel, then a slow trace: the longest span names the
cause (a pg query waiting on a lock, a slow upstream). Check CPU against requests (is it
throttled or at max replicas?).

### ServiceNoReadyPods
`kubectl -n <ns> describe deploy <name>` and the pod events: image pull, failing
readiness (`/ready` checks the database and Redis), quota (`kubectl describe quota`).

### PodCrashLooping
`kubectl -n <ns> logs <pod> --previous`. Config errors stop the process at start-up
with a clear message (missing environment variable, bad key file).

### CorePathAvailabilityBelowTarget
The 1-hour availability of the core path is under 99 %: follow ServiceHighErrorRate for
the service contributing most errors.

### PortalQuotaNearlyUsed
`kubectl -n <ns> describe quota portal-quota`. Usually prod at max replicas during a
rush. Either raise the quota in `platform/overlays/<env>` or lower max replicas.

### AdoptionAtMaxReplicas
adoption has been at 6 pods for 5 minutes: demand is above the plan. Check latency; if
the nodes have room, raise `maxReplicas` in `apps/adoption/values-prod.yaml`.

### EmailBacklogGrowing
Lag on email.queue above 100 and rising. Are email-worker pods at 4? Is Mailpit/SMTP
reachable (`kubectl logs deploy/email-worker`)? Emails are not lost; they wait.

### EventsDeadLettered
A message failed 5 times. Inspect it:
`kubectl -n <ns> exec redis-0 -c redis -- redis-cli XRANGE <stream>.dlq - + COUNT 5`.
Fix the cause, then re-add the data field to the original stream with XADD.

### KedaScalerErrors
KEDA cannot read Prometheus or Redis. `kubectl -n <ns> describe scaledobject <name>` and
`kubectl -n keda logs deploy/keda-operator`. Network policy on Redis allows the `keda` namespace.

### NodeNotReady
`kubectl describe node <node>`; on Kind, `docker ps` and `docker start <node>`.

### PostgresDown
Writes fail everywhere; reads from search still work. `kubectl -n <ns> logs postgres-0 -c postgres`.
If the data is damaged, restore from backup (above).

### PostgresConnectionsNearlyExhausted
Pool sizes times pods approach `max_connections` (300). Lower `database.poolMax` or max replicas.

### RedisDown
Events queue up in each service's outbox table and flow again when Redis returns;
the rate limiter fails open. `kubectl -n <ns> logs redis-0 -c redis`.

### RegistryMemberDown
One etcd member is down; quorum holds with 2. `kubectl -n registry get pods -o wide`;
a member on a drained node stays Pending until the node returns (anti-affinity).

### RegistryNoLeader
Two or more members down. The gateway keeps routing from its last copy and through
Service DNS. Bring members back; if a data volume is lost, delete that member's PVC and
pod, then `etcdctl member remove` and `member add` it again.

### ArgoAppOutOfSync
For prod this is normal after a promotion: run `scripts/sync-prod.sh`. For dev it means
auto-sync is failing: `kubectl -n argocd describe application <name>`.

### ArgoAppDegraded
Something Argo CD deployed is unhealthy: open the application in the Argo CD UI; the
red resource shows why. Roll back with `git revert` if it was a release.
