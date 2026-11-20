#!/usr/bin/env bash
# End-to-end functional test of one environment, through the public Gateway:
# home -> product -> add to cart -> cart -> checkout, plus health, version
# header and the Prometheus endpoint.
#
# Usage: platform/scripts/smoke-test.sh [dev|prod]
# Uses curl --resolve, so it works even without the /etc/hosts entry.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need curl kubectl

ENV="${1:-dev}"; NS="$(ns_for "$ENV")"; HOST="$(host_for "$ENV")"
IP="$(gateway_ip)"; [[ -n "$IP" ]] || die "Gateway has no address (kubectl -n gateway-infra get gateway)"
BASE="http://${HOST}"
JAR="$(mktemp)"; PF_PID=""; PF_LOG=""
cleanup() {
  rm -f "$JAR" "$PF_LOG"
  if [[ -n "$PF_PID" ]]; then kill "$PF_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

PASS=0; FAIL=0
check() { # check "<description>" <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; PASS=$((PASS+1)); else warn "FAIL: $desc"; FAIL=$((FAIL+1)); fi
}
c() { curl -sS --max-time 15 --resolve "${HOST}:80:${IP}" -b "$JAR" -c "$JAR" "$@"; }

# Note: no "grep -q" after a pipe: with pipefail, grep -q exits early, curl
# gets SIGPIPE and the whole check fails even though the text matched.
PRODUCT="OLJCESPC7Z"   # "Sunglasses" in the upstream catalog

step "Workloads in $NS"
check "all Deployments Available" k -n "$NS" wait --for=condition=Available deploy --all --timeout=120s
k -n "$NS" get deploy -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas,IMAGE:.spec.template.spec.containers[0].image' | sed 's/^/    /'

step "HTTP flow via Gateway $IP ($HOST)"
t_health()   { c "$BASE/_healthz" | grep -x ok >/dev/null; }
t_home()     { [[ "$(c -o /dev/null -w '%{http_code}' "$BASE/")" == 200 ]]; }
t_product()  { [[ "$(c -o /dev/null -w '%{http_code}' "$BASE/product/$PRODUCT")" == 200 ]]; }
t_add()      { [[ "$(c -o /dev/null -w '%{http_code}' -d product_id="$PRODUCT" -d quantity=1 "$BASE/cart")" =~ ^(200|302)$ ]]; }
t_cart()     { c "$BASE/cart" | grep -i sunglasses >/dev/null; }
# A card the payment service refuses (Visa Electron, unsupported brand) must
# be answered 402 with the shopper message, not 500 (ai-usage §3.26). The
# order fails, so the cart keeps its item for the valid checkout below.
t_declined() {
  local body code
  body="$(mktemp)"
  code="$(c -o "$body" -w '%{http_code}' -d email=someone@example.com -d street_address='1600 Amphitheatre Parkway' \
    -d zip_code=94043 -d city='Mountain View' -d state=CA -d country='United States' \
    -d credit_card_number=4917300800000000 -d credit_card_expiration_month=1 \
    -d credit_card_expiration_year=2039 -d credit_card_cvv=672 "$BASE/cart/checkout")"
  [[ "$code" == 402 ]] && grep 'Payment declined' "$body" >/dev/null && ! grep 'rpc error' "$body" >/dev/null
  local rc=$?
  rm -f "$body"
  return "$rc"
}
t_checkout() {
  c -L -d email=someone@example.com -d street_address='1600 Amphitheatre Parkway' -d zip_code=94043 \
    -d city='Mountain View' -d state=CA -d country='United States' \
    -d credit_card_number=4432801561520454 -d credit_card_expiration_month=1 \
    -d credit_card_expiration_year=2039 -d credit_card_cvv=672 \
    "$BASE/cart/checkout" | grep 'Your order is complete' >/dev/null
}
t_no_public_metrics() { ! c "$BASE/metrics" | grep boutique_frontend_ >/dev/null; }

check "GET /_healthz = ok"                      t_health
check "GET / -> 200"                            t_home
check "GET /product/$PRODUCT -> 200"            t_product
check "POST /cart (add item)"                   t_add
check "GET /cart shows the item"                t_cart
check "POST /cart/checkout, declined card -> 402" t_declined
check "POST /cart/checkout -> order complete"   t_checkout

VERSION="$(c -I "$BASE/" | awk -F': ' 'tolower($1)=="x-app-version"{print $2}' | tr -d '\r')"
if [[ -n "$VERSION" ]]; then ok "X-App-Version: $VERSION"; PASS=$((PASS+1)); else warn "FAIL: no X-App-Version header"; FAIL=$((FAIL+1)); fi

step "Metrics endpoint (not exposed by the Gateway)"
check "/metrics NOT reachable through the Gateway" t_no_public_metrics
# Port-forward rules, each one learnt from a wrong result on the cluster:
# - kubectl is started directly, not through k(): a backgrounded function runs
#   in a subshell, $! is the subshell and cleanup orphans kubectl;
# - no fixed local port: an orphan (or anything else) holding it made the
#   check read the metrics of the *previous* environment. With ":9090" kubectl
#   picks a free port and prints it; we read the port from its own output, so
#   the port we query is guaranteed to be this port-forward.
PF_LOG="$(mktemp)"; PF_PORT=""
kubectl --context "$KUBE_CONTEXT" -n "$NS" port-forward --address 127.0.0.1 svc/frontend-metrics :9090 >"$PF_LOG" 2>&1 & PF_PID=$!
for _ in $(seq 1 20); do   # up to 10s
  PF_PORT="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) -> 9090$/\1/p' "$PF_LOG" | head -1)"
  [[ -n "$PF_PORT" ]] && break
  kill -0 "$PF_PID" 2>/dev/null || break
  sleep 0.5
done
t_pf_ready() { [[ -n "$PF_PORT" ]] && kill -0 "$PF_PID" 2>/dev/null; }
metrics() { curl -s --max-time 5 "http://127.0.0.1:${PF_PORT}/metrics"; }
t_metrics() { t_pf_ready && metrics | grep '^boutique_frontend_http_requests_total' >/dev/null; }
check "port-forward to $NS/frontend-metrics ready (local port ${PF_PORT:-none})" t_pf_ready
check "frontend-metrics exposes boutique_frontend_http_requests_total" t_metrics
if t_pf_ready; then
  metrics | grep -E '^boutique_frontend_(build_info|http_requests_total\{method="POST",route="/cart/checkout")' | sed 's/^/    /' || true
fi

echo
if (( FAIL == 0 )); then echo "${C_GREEN}SMOKE TEST $ENV: PASS ($PASS checks)${C_OFF}"; else echo "${C_RED}SMOKE TEST $ENV: FAIL ($FAIL of $((PASS+FAIL)) checks failed)${C_OFF}"; exit 1; fi
