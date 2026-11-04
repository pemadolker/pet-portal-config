#!/usr/bin/env bash
# Creates every Secret the platform needs, with fresh random values. Secrets are
# never committed to Git: Argo CD deploys everything else, and the workloads
# reference these by name.
#
#   bootstrap/secrets.sh            # create what is missing (safe to re-run)
#   bootstrap/secrets.sh --rotate   # replace all of them (then restart the pods)
#
# Generated passwords are written to bootstrap/.secrets/credentials.txt (git-ignored)
# so you can log in. Production would use Sealed Secrets or External Secrets
# instead; see docs/runbook.md, "Secrets".
set -euo pipefail
cd "$(dirname "$0")"
ROTATE=false; [[ "${1:-}" == "--rotate" ]] && ROTATE=true
OUT=.secrets; mkdir -p "$OUT"; chmod 700 "$OUT"
CREDS="$OUT/credentials.txt"
SCHEMAS="signup login profile pet search shelter favorites adoption review history notification reporting"

rand() { openssl rand -base64 32 | tr -d '/+=' | cut -c1-"${1:-24}"; }
exists() { kubectl -n "$1" get secret "$2" >/dev/null 2>&1; }
apply_secret() { # namespace name args...
  local ns=$1 name=$2; shift 2
  if exists "$ns" "$name" && ! $ROTATE; then echo "  keep   $ns/$name"; return; fi
  kubectl -n "$ns" create secret "$@" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "  create $ns/$name"
}
ensure_ns() { # Namespaces are owned by Argo CD later; labels match platform/ so nothing is fought over.
  kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

echo "Namespaces"
for ns in argocd monitoring pet-portal-dev pet-portal-prod; do ensure_ns "$ns"; done
kubectl label ns pet-portal-dev pet-portal-prod app.kubernetes.io/part-of=pet-portal --overwrite >/dev/null

echo "TLS certificate (self-signed, for *.portal.local)"
if [[ ! -f "$OUT/tls.crt" ]] || $ROTATE; then
  openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes -keyout "$OUT/tls.key" -out "$OUT/tls.crt" \
    -subj "/CN=portal.local/O=Pet Adoption Portal" \
    -addext "subjectAltName=DNS:portal.local,DNS:*.portal.local,DNS:dev.portal.local,DNS:*.dev.portal.local" 2>/dev/null
fi
for ns in argocd monitoring pet-portal-dev pet-portal-prod; do
  apply_secret "$ns" portal-tls tls portal-tls --cert="$OUT/tls.crt" --key="$OUT/tls.key"
done

echo "Grafana admin"
GRAFANA_PW=$(rand)
if ! exists monitoring grafana-admin || $ROTATE; then
  apply_secret monitoring grafana-admin generic grafana-admin --from-literal=admin-user=admin --from-literal=admin-password="$GRAFANA_PW"
  echo "grafana   https://grafana.portal.local   admin / $GRAFANA_PW" >> "$CREDS"
else echo "  keep   monitoring/grafana-admin"; fi

for env in dev prod; do
  ns="pet-portal-$env"
  echo "Environment $env"
  # PostgreSQL superuser (used only by postgres itself, db-bootstrap and backups).
  apply_secret "$ns" postgres-superuser generic postgres-superuser --from-literal=password="$(rand 32)"
  # One password per service role; key = schema name (what the chart and db-bootstrap read).
  args=(); for s in $SCHEMAS; do args+=(--from-literal="$s=$(rand 32)"); done
  apply_secret "$ns" postgres-service-passwords generic postgres-service-passwords "${args[@]}"
  # RS256 key pair: login signs, the gateway verifies. Separate keys per environment,
  # so a dev token is worthless in prod.
  if ! exists "$ns" jwt-keys || $ROTATE; then
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$OUT/jwt-$env.pem" 2>/dev/null
    openssl pkey -in "$OUT/jwt-$env.pem" -pubout -out "$OUT/jwt-$env.pub"
    apply_secret "$ns" jwt-keys generic jwt-keys --from-file=private.pem="$OUT/jwt-$env.pem" --from-file=public.pem="$OUT/jwt-$env.pub"
    rm -f "$OUT/jwt-$env.pem"
  else echo "  keep   $ns/jwt-keys"; fi
  # First admin account (signup creates it on start; there are no demo accounts).
  if ! exists "$ns" bootstrap-admin || $ROTATE; then
    host=$([[ $env == prod ]] && echo portal.local || echo dev.portal.local)
    pw=$(rand)
    apply_secret "$ns" bootstrap-admin generic bootstrap-admin --from-literal=email="admin@$host" --from-literal=password="$pw"
    echo "admin     https://$host   admin@$host / $pw" >> "$CREDS"
  else echo "  keep   $ns/bootstrap-admin"; fi
  # Basic auth for the Mailpit inbox on mail.<host>.
  if ! exists "$ns" mailpit-basic-auth || $ROTATE; then
    pw=$(rand 16)
    apply_secret "$ns" mailpit-basic-auth generic mailpit-basic-auth --from-literal=auth="mail:$(openssl passwd -apr1 "$pw")"
    host=$([[ $env == prod ]] && echo portal.local || echo dev.portal.local)
    echo "mailpit   https://mail.$host   mail / $pw" >> "$CREDS"
  else echo "  keep   $ns/mailpit-basic-auth"; fi
done

chmod 600 "$CREDS" 2>/dev/null || true
echo
echo "Done. Logins are in bootstrap/$CREDS (git-ignored)."
