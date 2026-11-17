#!/usr/bin/env bash
# Shows the effective permissions of the team personas, using impersonation
# (kubectl --as / --as-group). Proves least privilege instead of claiming it.
#
# Usage: platform/scripts/rbac-check.sh
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need kubectl

# Subresources go in --subresource: "can-i create pods/exec" would be read as
# TYPE/NAME (a pod named "exec") and give wrong answers (seen for real).
can() { # can <ns> <user> <group> <verb> <resource> [subresource]
  local sub=(); [[ -n "${6:-}" ]] && sub=(--subresource "$6")
  if k auth can-i "$4" "$5" "${sub[@]}" -n "$1" --as "$2" --as-group "$3" >/dev/null 2>&1; then printf "  ${C_GREEN}%-4s${C_OFF}" yes; else printf "  ${C_RED}%-4s${C_OFF}" no; fi
}

printf "\n%-48s %-6s %-6s %-6s\n" "action" "dev" "prod" "prod"
printf "%-48s %-6s %-6s %-6s\n" "" "team" "team" "oncall"
for row in \
  "get pods|get|pods" \
  "read logs|get|pods|log" \
  "read secrets|get|secrets" \
  "exec into pods|create|pods|exec" \
  "port-forward|create|pods|portforward" \
  "patch deployments (restart/rollback)|patch|deployments.apps" \
  "delete pods|delete|pods" \
  "delete deployments|delete|deployments.apps" \
  "edit network policies|patch|networkpolicies.networking.k8s.io"; do
  IFS='|' read -r label verb res sub <<<"$row"
  printf "%-48s" "$label"
  can boutique-dev  alice team-boutique        "$verb" "$res" "$sub"
  can boutique-prod alice team-boutique        "$verb" "$res" "$sub"
  can boutique-prod bob   team-boutique-oncall "$verb" "$res" "$sub"
  echo
done

echo
echo "Workload identities (no service calls the Kubernetes API):"
for ns in boutique-dev boutique-prod; do
  printf "  %-14s frontend SA can list pods: " "$ns"
  k auth can-i list pods -n "$ns" --as "system:serviceaccount:${ns}:frontend" || true
  printf "  %-14s token mounted in frontend pod: " "$ns"
  k -n "$ns" get pod -l app=frontend -o jsonpath='{.items[0].spec.automountServiceAccountToken}{"\n"}' 2>/dev/null || echo "?"
done
