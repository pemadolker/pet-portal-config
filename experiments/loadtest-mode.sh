#!/usr/bin/env bash
# Raises (on) or restores (off) the gateway's rate limits through etcd live config.
# k6 sends everything from one IP, which the normal per-IP limits would block.
# No restart: the gateways watch these keys and log "gateway settings loaded".
#   experiments/loadtest-mode.sh on [prod|dev]
#   experiments/loadtest-mode.sh off [prod|dev]
set -euo pipefail
MODE=${1:?on|off}; ENV=${2:-prod}
etcdctl() { kubectl -n registry exec registry-etcd-0 -- etcdctl "$@"; }
P=/pet-portal/$ENV/config/gateway
if [[ $MODE == on ]]; then
  etcdctl put $P/rate_limit_per_minute 1000000
  etcdctl put $P/auth_rate_limit_per_minute 1000000
else
  etcdctl del $P/rate_limit_per_minute
  etcdctl del $P/auth_rate_limit_per_minute
fi
etcdctl get --prefix $P/
kubectl -n pet-portal-$ENV logs deploy/api-gateway --since=30s | grep "settings loaded" | tail -1 || true
