#!/usr/bin/env bash
# Failure scenarios for the demo and the runbook. Each one is a realistic
# L2 incident, injected as manual drift from Git (so Argo CD sees it too).
#
# Usage: platform/scripts/chaos.sh <scenario> [dev|prod]
#        platform/scripts/chaos.sh list
#        platform/scripts/chaos.sh restore [dev|prod]   # resync from Git
#
# DEV has self-heal off, so the fault stays until you fix it OR until the next
# commit reaches main: auto-sync then re-applies Git and silently removes it
# (seen for real). Do not push while a scenario is running.
# PROD has self-heal on: Argo CD reverts the fault by itself (worth showing!).
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need kubectl

SCENARIO="${1:-list}"; ENV="${2:-dev}"; NS="$(ns_for "$ENV")"

if [[ "$ENV" == "prod" && "$SCENARIO" != "list" && "$SCENARIO" != "restore" ]]; then
  warn "PROD: Argo CD self-heal should revert this within ~1 minute (watch: kubectl -n argocd get app boutique-prod -w)"
  read -r -p "    Continue? [y/N] " ans || ans=n
  [[ "$ans" =~ ^[Yy]$ ]] || exit 0
fi

# Inject only once Argo CD has synced the latest commit on main. Otherwise an
# auto-sync that lands after the injection re-applies Git and removes the
# fault within seconds (seen for real in the demo dry run: step 7 pushes the
# prod release, Argo CD picked it up ~90 s later, right after step 8 injected).
if [[ "$SCENARIO" != "list" && "$SCENARIO" != "restore" ]]; then
  need git
  head="$(git -C "$REPO_ROOT" ls-remote origin refs/heads/main | cut -f1)"
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || die "cannot read origin/main (got '$head')"
  k -n argocd annotate application "boutique-$ENV" argocd.argoproj.io/refresh=normal --overwrite >/dev/null
  wait_app_at_revision "boutique-$ENV" "$head" 300 \
    || die "boutique-$ENV is not synced at origin/main ${head:0:8}: retry when it is"
fi

case "$SCENARIO" in
  list)
    cat <<'EOF'
Scenarios (default env: dev):
  bad-image     frontend rolled out with a tag that does not exist  -> ImagePullBackOff, rollout stuck
  netpol-typo   typo in the paymentservice NetworkPolicy selector    -> checkout fails (500), rest of the shop OK
  oom           recommendationservice memory limit set to 32Mi       -> OOMKilled / CrashLoopBackOff
  redis-down    redis-cart scaled to 0                               -> cart and checkout fail
  restore       resync the environment from Git (Argo CD)
EOF
    ;;

  bad-image)
    step "[$NS] frontend -> boutique/frontend:9.9.9 (does not exist)"
    k -n "$NS" set image deploy/frontend server=boutique/frontend:9.9.9
    ok "injected. Observe:"
    echo "    kubectl -n $NS rollout status deploy/frontend --timeout=60s   # stalls"
    echo "    kubectl -n $NS get pods -l app=frontend                       # new pod ImagePullBackOff, old pods still Running"
    echo "    kubectl -n $NS describe pod -l app=frontend | grep -A8 Events"
    ;;

  netpol-typo)
    step "[$NS] NetworkPolicy paymentservice: allow from app=checkout-service (typo, the real label is checkoutservice)"
    k -n "$NS" patch networkpolicy paymentservice --type=json \
      -p '[{"op":"replace","path":"/spec/ingress/0/from/0/podSelector/matchLabels/app","value":"checkout-service"}]'
    # kindnet does not cut existing connections and gRPC keeps them open: without
    # a restart checkout keeps working on the old connection (seen for real).
    # The restart plays the part of "the next deploy", which in real life is
    # when this kind of fault surfaces.
    k -n "$NS" rollout restart deploy/checkoutservice >/dev/null
    k -n "$NS" rollout status deploy/checkoutservice --timeout=120s >/dev/null
    ok "injected (checkoutservice restarted to drop its existing connection). Place an order (or run smoke-test.sh $ENV), then:"
    echo "    kubectl -n $NS logs deploy/frontend --since=5m | grep -i checkout | grep -iE 'error|fail' | tail -3"
    echo "    kubectl -n $NS logs deploy/checkoutservice --since=5m | tail -5"
    echo "    kubectl -n $NS get networkpolicy paymentservice -o yaml"
    ;;

  oom)
    step "[$NS] recommendationservice memory limit -> 32Mi"
    k -n "$NS" set resources deploy/recommendationservice -c server --requests=memory=16Mi --limits=memory=32Mi
    ok "injected. Observe:"
    echo "    kubectl -n $NS get pods -l app=recommendationservice -w"
    echo "    kubectl -n $NS describe pod -l app=recommendationservice | grep -B2 -A4 'Last State'"
    ;;

  redis-down)
    step "[$NS] redis-cart scaled to 0"
    k -n "$NS" scale deploy/redis-cart --replicas=0
    ok "injected. Add something to the cart, then:"
    echo "    kubectl -n $NS logs deploy/cartservice --since=5m | tail -5"
    echo "    kubectl -n $NS get endpoints redis-cart"
    ;;

  restore)
    step "[$NS] resync boutique-$ENV from Git"
    argocd_sync "boutique-$ENV"
    # A NetworkPolicy patch is drift on a managed object: sync restores it.
    wait_app_healthy "boutique-$ENV" 300
    k -n "$NS" rollout status deploy/frontend --timeout=180s
    ;;

  *) die "unknown scenario '$SCENARIO' (try: $0 list)" ;;
esac
