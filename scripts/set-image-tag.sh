#!/usr/bin/env bash
# Sets image.tag for services in one environment. Used by the app repo's CI
# (dev, after every build of main) and by the promote workflow (prod).
#   scripts/set-image-tag.sh dev 3f2a9c1 adoption pet        # some services
#   scripts/set-image-tag.sh dev 3f2a9c1 --all               # all 15
#   scripts/set-image-tag.sh prod --from-dev --all            # promote: copy dev's tags to prod
set -euo pipefail
cd "$(dirname "$0")/.."
ENV=${1:?env}; shift
FROM_DEV=false; TAG=""
if [[ "${1:-}" == "--from-dev" ]]; then FROM_DEV=true; shift; else TAG=${1:?tag}; shift; fi
if [[ "${1:-}" == "--all" ]]; then set -- $(ls apps); fi
for svc in "$@"; do
  f="apps/$svc/values-$ENV.yaml"
  [[ -f "$f" ]] || { echo "no such file: $f"; exit 1; }
  t=$TAG
  $FROM_DEV && t=$(grep -E '^  tag:' "apps/$svc/values-dev.yaml" | sed -E 's/^  tag: "?([^" ]+)"?.*/\1/')
  sed -i.bak -E "s/^(  tag: )\"?[^\" ]+\"?/\1\"$t\"/" "$f" && rm -f "$f.bak"
  echo "$ENV/$svc -> $t"
done
