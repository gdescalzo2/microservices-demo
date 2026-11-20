#!/usr/bin/env bash
# Rollback of one environment. Two paths, on purpose:
#
#   GitOps (default):  git revert of the last commit that touched the overlay
#                      -> push -> Argo CD sync. Auditable, Git stays the truth.
#   --emergency:       kubectl rollout undo, for when Git/CI is unavailable.
#                      In PROD self-heal would immediately undo the undo, so
#                      auto-sync is suspended first; you MUST then fix Git and
#                      re-enable it (the script prints how).
#
# Usage: platform/scripts/rollback.sh <dev|prod> [--emergency [service]]
#   service (emergency only): frontend (default), checkoutservice or
#   paymentservice. The GitOps path reverts whatever the last overlay commit
#   changed and checks every service built from this fork.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need git kubectl kustomize curl jq

ENV="${1:?usage: $0 <dev|prod> [--emergency [service]]}"; MODE="${2:-gitops}"
NS="$(ns_for "$ENV")"; APP="boutique-$ENV"; OVERLAY="platform/deploy/overlays/$ENV"

if [[ "$MODE" == "--emergency" ]]; then
  SERVICE="${3:-frontend}"
  image_key_for "$SERVICE" >/dev/null   # validates the name
  step "[$NS] EMERGENCY rollback of $SERVICE with kubectl"
  if [[ "$ENV" == "prod" ]]; then
    warn "suspending Argo CD auto-sync for $APP (otherwise self-heal reverts the undo)"
    k -n argocd patch application "$APP" --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
  fi
  k -n "$NS" rollout history "deploy/$SERVICE"
  k -n "$NS" rollout undo "deploy/$SERVICE"
  k -n "$NS" rollout status "deploy/$SERVICE" --timeout=300s
  ok "running the previous ReplicaSet again"
  warn "Git no longer matches the cluster. To close the incident:"
  echo "    1. platform/scripts/rollback.sh $ENV            # revert the bad commit in Git"
  if [[ "$ENV" == "prod" ]]; then
    echo "    2. re-enable auto-sync + self-heal:"
    echo "       kubectl -n argocd patch application $APP --type merge -p '{\"spec\":{\"syncPolicy\":{\"automated\":{\"prune\":true,\"selfHeal\":true}}}}'"
  fi
  exit 0
fi

step "[$ENV] GitOps rollback: revert the last change to $OVERLAY"
git -C "$REPO_ROOT" pull --ff-only
BAD="$(git -C "$REPO_ROOT" log -1 --format=%h -- "$OVERLAY")"
[[ -n "$BAD" ]] || die "no commit found for $OVERLAY"
git -C "$REPO_ROOT" --no-pager log -1 --format='    reverting %h  %s  (%an, %ar)' "$BAD"
git -C "$REPO_ROOT" revert --no-edit "$BAD"
git -C "$REPO_ROOT" push
SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
ok "pushed revert ${SHA:0:8}"
# What the overlay declares after the revert is what must be running: every
# boutique/* image (our services), whichever one the reverted commit changed.
EXPECTED="$(kustomize build "$REPO_ROOT/$OVERLAY" | sed -n 's|^ *image: boutique/\([a-z]*\):\([0-9][0-9.]*\)$|\1 \2|p' | sort -u)"
[[ -n "$EXPECTED" ]] || die "cannot read the boutique/* images from $OVERLAY after the revert"
echo "    expected after rollback:"
while read -r svc ver; do echo "      boutique/$svc:$ver"; done <<<"$EXPECTED"

step "Argo CD sync + rollout"
argocd_sync "$APP" "$SHA"
# 600s covers the sync retry backoff (see platform/gitops/applications.yaml).
wait_app_at_revision "$APP" "$SHA" 600 || die "Argo CD did not reach ${SHA:0:8}"
while read -r svc ver; do
  verify_own_service "$ENV" "$svc" "$ver" || die "rollback not verified ($svc)"
done <<<"$EXPECTED"
k -n "$NS" get pods -l 'app in (frontend,checkoutservice,paymentservice)' -o custom-columns='POD:.metadata.name,IMAGE:.spec.containers[0].image'
