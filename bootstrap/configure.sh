#!/usr/bin/env bash
# One-time setup: points the repository at your GitHub organisation.
#   bootstrap/configure.sh <github-org-or-user> [config-repo-name] [app-repo-name]
# Rewrites the CHANGE-ME placeholders in the Argo CD manifests and env files,
# then commit and push.
set -euo pipefail
cd "$(dirname "$0")/.."
ORG=${1:?usage: bootstrap/configure.sh <github-org-or-user> [config-repo] [app-repo]}
CONFIG_REPO=${2:-pet-portal-config}
ORG_LC=$(echo "$ORG" | tr '[:upper:]' '[:lower:]')   # container registries need lower case
files=$(grep -rl "CHANGE-ME" argocd envs bootstrap/*.sh docs 2>/dev/null | grep -v configure.sh || true)
for f in $files; do
  sed -i.bak -e "s#https://github.com/CHANGE-ME/pet-portal-config.git#https://github.com/${ORG}/${CONFIG_REPO}.git#g" \
             -e "s#ghcr.io/CHANGE-ME/#ghcr.io/${ORG_LC}/#g" "$f" && rm -f "$f.bak"
  echo "updated $f"
done
echo "Now: git commit -am 'Configure for ${ORG}' && git push"
