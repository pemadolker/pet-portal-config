# pet-portal-config

Everything that runs the Pet Adoption Portal on Kubernetes: the Helm chart, the
Kustomize platform layer, the Argo CD applications, the monitoring stack, the
dashboards and alerts, and the experiments that prove it works.

DSO202 Scaling, Orchestration, Monitoring and Observability, College of Science and Technology.
Team: Dechen Wangdra Sherpa, Tandin Zangmo, Pema Dolker. Tutor: Mr. Saroj Sanyasi.

The service code lives in the second repository, **pet-portal-app**. Argo CD only
ever reads this repository; CI only ever writes image tags into it. Nobody runs
`kubectl apply` on the portal by hand.

```
 pet-portal-app ──push──▶ CI: test, build 15 images, scan, push to GHCR
                                   │ writes apps/*/values-dev.yaml (image.tag)
                                   ▼
 pet-portal-config ◀── Argo CD watches main ──▶ Kind cluster
   dev:  synced automatically (self-heal)          pet-portal-dev
   prod: promote PR + manual sync (approval)       pet-portal-prod
```

## How the final-project requirements are met

| Brief | Where |
|---|---|
| a. Helm charts | `charts/microservice/`: one generic chart used 15 times; each service is a small values file in `apps/<service>/`. |
| b. GitOps with Argo CD | `argocd/`: app of apps per environment, sync waves, AppProjects with roles; dev auto-sync with self-heal, prod manual sync; rollback is `git revert`. CI in both repos. |
| c. Monitoring and observability | kube-prometheus-stack (Prometheus, Alertmanager, Grafana), Loki + Alloy (logs), OpenTelemetry Collector + Tempo (traces); values in `observability/values/`. Logs, traces and metrics are linked by trace id. |
| d. Autoscaling on custom metrics | KEDA: **adoption** on request rate from Prometheus, **email-worker** on Redis Stream lag; five edge/read services on CPU. `apps/*/values-prod.yaml`. |
| e. Dashboards | Seven Grafana dashboards as code in `observability/dashboards/` (cluster, namespaces, services RED, adoption rush, autoscaling, data stores, logs and traces) and 22 rules in `observability/alerts/`. |
| HA and capacity plan | `docs/ha-capacity-plan.md` (measured figures), PodDisruptionBudgets, topology spread, 3-member etcd. |
| Evidence | `experiments/README.md`: E1 to E10 with scripts and pass criteria. |

## Layout

```
charts/microservice/     the one generic chart (Deployment, Service, ServiceAccount, NetworkPolicy,
                         ServiceMonitor, KEDA ScaledObject, PDB, migration Job, Ingress, ConfigMap)
apps/<service>/          values.yaml (what this service is), values-dev.yaml, values-prod.yaml (tag, scaling)
envs/dev.yaml prod.yaml  settings shared by every service in an environment
platform/base            per-environment platform: quota, limits, deny-all policies, PostgreSQL,
                         db-bootstrap, nightly backup, Redis, Mailpit
platform/overlays/       dev and prod: namespace (Pod Security "restricted"), sizes, RBAC
platform/cluster/        tool namespaces and the 3-member etcd service registry
observability/           Helm values for the add-ons, dashboards (build.py), alert rules + tests
argocd/                  projects, root-cluster/root-dev/root-prod, apps/ (renders the Applications)
bootstrap/               Kind cluster, Argo CD install, secrets, one-command bootstrap
scripts/                 validate.sh (what CI checks), sync-prod.sh (release prod), set-image-tag.sh
experiments/             k6 scripts and shell scripts for E1 to E10
docs/                    runbook, HA and capacity plan
```

## Start from nothing

You need Docker, kind 0.30 or newer, kubectl and openssl, and about 12 GB of free memory
(see the capacity plan for smaller machines).

```bash
# 1. Point the repo at your GitHub account, then push it (Argo CD reads it from GitHub)
bootstrap/configure.sh <your-github-org>
git commit -am "Configure" && git push

# 2. Cluster, Calico, secrets, Argo CD, add-ons, dev, prod. Prints the time taken (E1).
#    APP_REPO builds the 15 images and loads them into Kind, so no registry is needed yet.
#    Later, CI pushes images to GHCR instead (make the packages public so Kind can pull them).
APP_REPO=../pet-portal-app bootstrap/bootstrap.sh

# 3. Host names (the Ingress listens on 80/443 of this machine)
echo "127.0.0.1 portal.local dev.portal.local grafana.portal.local argocd.portal.local mail.portal.local mail.dev.portal.local" | sudo tee -a /etc/hosts
```

Logins are written to `bootstrap/.secrets/credentials.txt`. There are no demo accounts:
log in as the admin, and shelters register through the website and wait for approval.

## Day to day

| Task | How |
|---|---|
| Release to dev | Merge to main in pet-portal-app. CI builds, then commits the tag here; Argo CD syncs dev. |
| Release to prod | Actions → **promote** (opens a PR copying dev's tags) → review and merge → `scripts/sync-prod.sh`. |
| Roll back | `git revert <commit>` here, push; dev heals itself, prod: `scripts/sync-prod.sh <service>`. |
| Change a service's settings | Edit `apps/<service>/values*.yaml`, open a PR; CI runs `scripts/validate.sh`. |
| Change a dashboard | Edit `observability/dashboards/build.py`, run it, commit the JSON. |
| Check everything locally | `scripts/validate.sh` (needs helm, kustomize, kubeconform, promtool). |

More in `docs/runbook.md`.
