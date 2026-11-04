# High availability and capacity plan

What keeps the portal up, what it costs in memory and CPU, what it can take, and
what it deliberately does not promise. Figures marked **measured** were taken while
building the project; the rest are budgets. Re-measure on your own cluster
(`kubectl top pods -A`, the "Namespaces" dashboard) and update the tables.

## 1. Measured while building (before the cluster)

Environment: the 14 Node services running natively on a 2-vCPU, 7 GB machine against
PostgreSQL 16 and Redis 7, with the gateway in front, k6 and the test scripts on the
same machine (so the load generator competed for the same 2 CPUs).

| What | Result |
|---|---|
| One-winner race: 2,000 adopters apply for 10 pets at the same instant (one adoption process) | **10 accepted, 1,990 `PET_TAKEN`, 0 other**; burst finished in 3.4 s; database holds exactly one application per pet |
| Same race through k6 (500 adopters, 100 VUs) | 10 accepted, 490 taken, 0 other |
| Adoption availability endpoint through the gateway, one process each, ramp to about 1,470 req/s | 30,837 requests, **0 failed, p95 105 ms** |
| Steady browsing mix, 40 req/s for 20 s | 0 failed, p95 6 ms |
| Memory per service at idle (RSS) | **82 to 91 MiB** (Node 22, tracing on) |
| Memory after the 2,000-user run (RSS) | login 162 MiB (scrypt: 8 MiB per hash, 4 at a time), adoption 119 MiB, gateway 108 MiB, others 87 to 96 MiB |
| Password hash (scrypt N=2^13, r=8, p=10) | about 220 ms of CPU each, by design |

Consequences for the plan:

* The proposal assumed 64 MiB per pod. Node.js needs about 90 MiB, so requests are
  96 to 128 MiB and limits 192 to 256 MiB, with the V8 heap capped below the limit
  (`--max-old-space-size`) so garbage collection happens before an OOM kill.
* login is CPU-bound on purpose (password hashing), which is why it scales on CPU.
* One adoption process handled far more than 50 req/s of cheap reads, so the KEDA
  threshold of 50 req/s per pod is conservative. E3's baseline step sets it from a
  measurement on the cluster (0.7 x one pod's capacity).

## 2. Pods and replicas

| Service | dev | prod at rest | prod max | Scales on | Why |
|---|---|---|---|---|---|
| frontend | 1 | 2 | 4 | CPU 70 % | static files, cheap |
| api-gateway | 1 | 2 | 4 | CPU 70 % | every request passes through it |
| login | 1 | 2 | 4 | CPU 70 % | password hashing is CPU |
| pet, search | 1 | 2 each | 4 each | CPU 70 % | read-heavy browsing |
| adoption | 1 | 2 | 6 | request rate (Prometheus), 50/s per pod | rate rises before CPU does |
| email-worker | 1 | 1 | 4 | Redis stream lag, 20 per pod | waiting work is the real load |
| signup, profile, shelter, favorites, review, history, notification, reporting | 1 | 1 each | 1 | fixed | low traffic, off the hot path |
| **Total app pods** | **15** | **21** | **38** | | |

Data and platform per environment: PostgreSQL 1, Redis 1, Mailpit 1 (plus a nightly
backup Job). Shared: 3 etcd registry members.

## 3. Memory budget (requests, which is what the scheduler reserves)

| Component | Request | Notes |
|---|---|---|
| prod services at rest (21 pods) | about 2.2 GiB | gateway/login/adoption 128 Mi, others 96 Mi, frontend 32 Mi with exporter |
| prod services at max (38 pods) | about 4.0 GiB | |
| dev services (15 pods) | about 1.5 GiB | turn dev off during load tests to win this back |
| PostgreSQL + Redis + Mailpit, per environment | about 0.4 GiB | x 2 |
| etcd registry (3) | 0.2 GiB | |
| Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter (x4), operator | about 0.9 GiB | Prometheus 512 Mi, retention 3 days |
| Loki, Tempo, Alloy (x4), OpenTelemetry Collector | about 0.9 GiB | Loki and Tempo single binary, local disk |
| Argo CD, KEDA, ingress-nginx, metrics-server, Calico | about 1.2 GiB | |
| Kind node containers and Kubernetes system pods | about 2.0 GiB | |
| **Total, prod at rest + dev** | **about 9.6 GiB** | |
| **Total, prod at max, dev off** | **about 9.9 GiB** | |

So a machine with **12 GB free** runs everything; with 8 GB, stop dev during tests
(`--no-prod` while developing, or scale dev to 0 while testing prod).

Levers if memory is short, in order (proposal section 11): stop dev during load
tests; lower Loki/Tempo retention; stop Tempo; lower Prometheus retention; lower the
max pod counts in `apps/*/values-prod.yaml`.

### Quotas (platform/overlays)

| Namespace | requests.cpu | requests.memory | limits.memory | pods |
|---|---|---|---|---|
| pet-portal-dev | 2 | 3 GiB | 5 GiB | 40 |
| pet-portal-prod | 4 | 6 GiB | 10 GiB | 70 |

Prod at max uses about 4.4 GiB of its 6 GiB request quota, leaving room for a
rolling update (one extra pod per Deployment, `maxSurge: 1`) and the migration Jobs.
The PortalQuotaNearlyUsed alert fires at 90 %.

## 4. Load model

Proposal scenario: 2,000 users arriving in one minute for 10 pets, about 33 new
users per second. Each user opens a pet page (pet, availability, shelter, reviews,
search: 5 calls), applies (1 call) and checks the result (2 calls), about 8 requests,
so roughly **270 req/s at the gateway** at the peak, of which about 100 req/s reach
adoption. At 50 req/s per pod that is 2 to 3 adoption pods; 6 is the safety ceiling.
The AdoptionAtMaxReplicas alert says when the ceiling itself is the problem.

## 5. High availability: what survives what

| Failure | What happens | Why | Tested by |
|---|---|---|---|
| A pod crashes | Liveness probe restarts it; the Service routes to the other pod (core services have 2+) | probes, replicas, PDB | E6 |
| A release | New pod must be Ready before an old one goes; the old one leaves the etcd registry and drains for 5 s before stopping | `maxUnavailable: 0`, readiness, graceful shutdown | E5 |
| A bad release | New pods never become Ready, old pods keep serving; `git revert` restores | rolling update + GitOps | E6 |
| A worker node lost or drained | Core services keep 1+ pod on other nodes (topology spread, PDB minAvailable 1); one-pod services restart elsewhere after a short gap | spread + PDB | E7 |
| One etcd member lost | 2 of 3 keep quorum; reads and writes continue; the member rejoins | 3 members, hard anti-affinity | E8 |
| All of etcd lost | The gateway keeps its last copy of the routes and falls back to Service DNS; services keep retrying registration | fallback in api-gateway | (by design) |
| Redis slow or down | Pages still load (reads do not need Redis); events wait in each service's outbox table and are sent when Redis is back; rate limiting fails open | transactional outbox | (by design) |
| A dependency slow (for example shelter) | Callers time out after 3 s, retry GETs twice, then a circuit breaker fails fast for 10 s | client.js | E10 (`shelter` fault) |
| A duplicate event | Ignored: each consumer records event ids in the same transaction as its own change | processed_events | unit of every consumer |
| A poison event | After 5 failed attempts it moves to `<stream>.dlq`; EventsDeadLettered alert | consumer | (by design) |

### Not promised (proposal section 12)

* **The control plane.** Kind has one control-plane node; if it goes, the cluster cannot
  be changed (running pods keep serving until a node or pod fails).
* **PostgreSQL.** One instance per environment on a node-local volume: if it or its
  node fails, writes stop until it is back. Mitigations: nightly `pg_dump` (7 days),
  a manual backup before every drill, PostgresDown alert, and a restore procedure in
  the runbook. A real deployment would use a replicated operator (CloudNativePG) or a
  managed database.
* **Load beyond the max pod counts**, and measurements as benchmarks: k6 runs on the
  same machine as the cluster, so results understate what the system can do.

## 6. Availability targets

* Core path (frontend, gateway, login, pet, search, adoption): **above 99 %** of
  requests succeed, **p95 under 500 ms**, at the prepared load. Shown live on the
  "Service overview" dashboard and recorded as `corepath:availability:ratio1h`;
  CorePathAvailabilityBelowTarget alerts below 99 %.
* Zero failed requests during a rolling update (E5).
* Recovery of a one-pod service after losing its node: measured in E7 (expected under
  60 s: reschedule, start, readiness).
