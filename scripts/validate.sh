#!/usr/bin/env bash
# Everything CI checks before Argo CD sees a change (proposal section 7):
#   1. helm lint + helm template for all 15 services x 2 environments
#   2. kustomize build for platform/, observability/ and the Argo CD install
#   3. kubeconform (strict) against Kubernetes and CRD schemas
#   4. promtool: alert rules parse, and their unit tests pass
# Needs: helm, kustomize, kubeconform, promtool (CI installs them).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
KC=(kubeconform -strict -summary -kubernetes-version "${KUBE_VERSION:-1.33.0}" -schema-location default
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json')

echo "== helm lint and template"
helm lint charts/microservice -f envs/prod.yaml -f apps/adoption/values.yaml -f apps/adoption/values-prod.yaml >/dev/null
for env in dev prod; do
  for svc in $(ls apps); do
    helm template "$svc" charts/microservice -n "pet-portal-$env" \
      -f "envs/$env.yaml" -f "apps/$svc/values.yaml" -f "apps/$svc/values-$env.yaml" > "$OUT/$env-$svc.yaml"
  done
done
for e in cluster dev prod; do helm template "root-$e" argocd/apps -f argocd/apps/values.yaml -f "argocd/apps/values-$e.yaml" > "$OUT/argocd-$e.yaml"; done
echo "   $(ls "$OUT" | wc -l) releases rendered"

echo "== kustomize build"
for k in platform/overlays/dev platform/overlays/prod platform/cluster observability; do
  kustomize build "$k" > "$OUT/kustomize-$(echo "$k" | tr / -).yaml"
done

echo "== kubeconform"
"${KC[@]}" "$OUT"/*.yaml argocd/projects.yaml argocd/root-*.yaml

echo "== promtool"
python3 -c "import yaml,sys;d=yaml.safe_load(open('observability/alerts/pet-portal-rules.yaml'));yaml.safe_dump({'groups':d['spec']['groups']},open('observability/alerts/rules.extracted.yaml','w'))"
promtool check rules observability/alerts/rules.extracted.yaml
(cd observability/alerts && promtool test rules tests.yaml)
rm -f observability/alerts/rules.extracted.yaml

echo "== dashboards are up to date"
python3 observability/dashboards/build.py >/dev/null
git diff --quiet -- observability/dashboards || { echo "Run python3 observability/dashboards/build.py and commit the JSON"; exit 1; }
echo "All checks passed."
