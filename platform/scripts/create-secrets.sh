#!/usr/bin/env bash
# Creates the Redis credentials for each environment, out of Git.
#
# Usage: platform/scripts/create-secrets.sh                  # dev + prod, create if missing
#        platform/scripts/create-secrets.sh --rotate         # new password + restart
#        platform/scripts/create-secrets.sh boutique-team-a-dev   # other namespace(s)
#
# Each environment gets its own random password (dev and prod never share
# credentials). The value is never printed. In production this script is
# replaced by External Secrets Operator / Sealed Secrets / Vault: see
# docs/challenge/security.md.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need kubectl openssl

ROTATE=0; [[ "${1:-}" == "--rotate" ]] && { ROTATE=1; shift; }
NAMESPACES=("$@")
if [[ ${#NAMESPACES[@]} -eq 0 ]]; then
  for env in "${ENVS[@]}"; do NAMESPACES+=("$(ns_for "$env")"); done
fi

for ns in "${NAMESPACES[@]}"; do
  # The namespace is normally created by Argo CD; create it early so the
  # Secret exists before the first sync (Argo CD then adopts the namespace).
  k get ns "$ns" >/dev/null 2>&1 || k create ns "$ns" >/dev/null

  if k -n "$ns" get secret redis-auth >/dev/null 2>&1 && [[ $ROTATE -eq 0 ]]; then
    ok "$ns/redis-auth exists (use --rotate to change it)"
    continue
  fi

  pw="$(openssl rand -hex 24)"
  k -n "$ns" create secret generic redis-auth \
    --from-literal=password="$pw" \
    --from-literal=connection-string="redis-cart:6379,password=${pw}" \
    --dry-run=client -o yaml \
    | k label --local -f - app.kubernetes.io/part-of=online-boutique -o yaml \
    | k apply -f - >/dev/null
  unset pw
  ok "$ns/redis-auth written"

  if [[ $ROTATE -eq 1 ]] && k -n "$ns" get deploy redis-cart >/dev/null 2>&1; then
    # Env vars are read at start-up: restart Redis and its only client.
    # Cart contents are lost (Redis uses emptyDir in this demo anyway).
    k -n "$ns" rollout restart deploy/redis-cart deploy/cartservice >/dev/null
    k -n "$ns" rollout status deploy/redis-cart --timeout=120s >/dev/null
    k -n "$ns" rollout status deploy/cartservice --timeout=180s >/dev/null
    ok "$ns: redis-cart and cartservice restarted with the new password"
  fi
done
