#!/bin/sh
# Creates one login role and one schema per service in the portal database
# (proposal decision D2: one PostgreSQL instance per environment, one schema and
# role per service). Safe to run again: it only creates what is missing and
# resets passwords to the values given.
#
# Needs: PGHOST, PGUSER (a superuser), PGPASSWORD, PGDATABASE, and each service's
# password, either as <SCHEMA>_DB_PASSWORD (for example PET_DB_PASSWORD) or as a
# file $PASSWORDS_DIR/<schema> (for example /passwords/pet).
# In Kubernetes this runs as the db-bootstrap Job with the postgres-service-passwords
# Secret mounted at /passwords, the same Secret the services read their password from.
set -eu
export PGOPTIONS="-c client_min_messages=warning"

SCHEMAS="signup login profile pet search shelter favorites adoption review history notification reporting"

until pg_isready -q; do echo "waiting for postgres at ${PGHOST}..."; sleep 2; done

psql -v ON_ERROR_STOP=1 -q <<'SQL'
-- Nobody gets anything by default; each role is granted only its own schema.
REVOKE ALL ON SCHEMA public FROM PUBLIC;
SQL
psql -v ON_ERROR_STOP=1 -q -c "REVOKE CONNECT ON DATABASE \"${PGDATABASE}\" FROM PUBLIC;"

for s in $SCHEMAS; do
  var="$(echo "$s" | tr '[:lower:]' '[:upper:]')_DB_PASSWORD"
  pw="$(eval echo "\${$var:-}")"
  if [ -z "$pw" ] && [ -n "${PASSWORDS_DIR:-}" ] && [ -f "$PASSWORDS_DIR/$s" ]; then pw="$(cat "$PASSWORDS_DIR/$s")"; fi
  if [ -z "$pw" ]; then echo "missing password for $s ($var or \$PASSWORDS_DIR/$s)" >&2; exit 1; fi
  role="svc_${s}"
  psql -v ON_ERROR_STOP=1 -q -v role="$role" -v schema="$s" -v pw="$pw" -v db="$PGDATABASE" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'role')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role') \gexec
ALTER ROLE :"role" WITH LOGIN PASSWORD :'pw' NOSUPERUSER NOCREATEDB NOCREATEROLE CONNECTION LIMIT 60;
ALTER ROLE :"role" SET search_path = :"schema";
GRANT CONNECT ON DATABASE :"db" TO :"role";
CREATE SCHEMA IF NOT EXISTS :"schema" AUTHORIZATION :"role";
SQL
  echo "role ${role} and schema ${s} ready"
done
echo "bootstrap complete"
