#!/usr/bin/env bash
# GitOps release of a new version of one of our services to one environment:
#   build + load image -> change the tag in the overlay -> commit + push
#   -> Argo CD syncs -> rolling update (maxUnavailable 0).
#
# Usage: platform/scripts/release.sh <dev|prod> <version> [service]   e.g. dev 1.1.0
#        SKIP_BUILD=1 platform/scripts/release.sh prod 1.1.0 [service]  # image already built (promotion)
# service: frontend (default), checkoutservice or paymentservice. The
# overlay must already have an images entry for it: the first introduction
# of a service built from this fork is a hand-written commit (see the
# comments in platform/deploy/overlays/*/kustomization.yaml).
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need git kubectl kustomize docker curl jq

ENV="${1:?usage: $0 <dev|prod> <version> [service]}"; VERSION="${2:?usage: $0 <dev|prod> <version> [service]}"
SERVICE="${3:-frontend}"
NS="$(ns_for "$ENV")"; OVERLAY="$REPO_ROOT/platform/deploy/overlays/$ENV"
[[ -d "$OVERLAY" ]] || die "no overlay for '$ENV'"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be semver X.Y.Z (got '$VERSION')"
KEY="$(image_key_for "$SERVICE")"
IMAGE="boutique/${SERVICE}"

[[ -z "$(git -C "$REPO_ROOT" status --porcelain -- platform/deploy)" ]] \
  || die "uncommitted changes under platform/deploy: commit or stash them first"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  "$REPO_ROOT/platform/scripts/build-image.sh" "$SERVICE" "$VERSION"
else
  # Promotion: the image must already be on the kind node, or the rollout
  # would end in ImagePullBackOff (there is no registry to pull from).
  image_on_node "${IMAGE}:${VERSION}" \
    || die "${IMAGE}:${VERSION} is not on the kind node: build it first (build-image.sh ${SERVICE} ${VERSION})"
  ok "${IMAGE}:${VERSION} already on the kind node"
fi

step "Overlay $ENV: $IMAGE -> $VERSION"
KREL="platform/deploy/overlays/$ENV/kustomization.yaml"
BEFORE="$(mktemp)"; AFTER="$(mktemp)"; trap 'rm -f "$BEFORE" "$AFTER"' EXIT
kustomize build "$OVERLAY" > "$BEFORE"
CURRENT="$(awk -v p="image: ${IMAGE}:" 'index($0, p) {print $2; exit}' "$BEFORE")"
[[ -n "$CURRENT" ]] || die "$ENV does not run ${IMAGE} yet: introduce it in $KREL with a hand-written commit first"
echo "    current: $CURRENT"
[[ "$CURRENT" != "${IMAGE}:${VERSION}" ]] \
  || die "$ENV already declares ${IMAGE}:${VERSION} in Git: nothing to release"
# Only the newTag value changes (see set_image_tag in lib.sh for why not
# "kustomize edit set image"). Any check below failing restores the file.
restore_overlay() { git -C "$REPO_ROOT" checkout -- "$KREL"; }
set_image_tag "$REPO_ROOT/$KREL" "$KEY" "$VERSION" \
  || die "could not set the newTag in $KREL: file left unchanged"
NUMSTAT="$(git -C "$REPO_ROOT" diff --numstat -- "$KREL")"
[[ "$NUMSTAT" == $'1\t1\t'"$KREL" ]] \
  || { restore_overlay; die "expected exactly one changed line in $KREL, got '${NUMSTAT:-no change}'"; }
kustomize build "$OVERLAY" > "$AFTER" || { restore_overlay; die "kustomize build failed after the edit"; }
# The rendered manifests must differ by this service's image line only.
# Exactly two diff lines, whatever the indentation: old image out, new in.
RENDER_DIFF="$(diff "$BEFORE" "$AFTER" | grep '^[<>]' || true)"
if [[ "$(grep -c . <<<"$RENDER_DIFF")" != 2 ]] \
  || ! grep -Ex "< +image: ${CURRENT//./\\.}" <<<"$RENDER_DIFF" >/dev/null \
  || ! grep -Ex "> +image: ${IMAGE}:${VERSION//./\\.}" <<<"$RENDER_DIFF" >/dev/null; then
  restore_overlay; die "rendered manifests changed beyond the $SERVICE image:"$'\n'"$RENDER_DIFF"
fi
ok "only the newTag line changed; rendered output differs by the $SERVICE image only"
git -C "$REPO_ROOT" --no-pager diff -- "$KREL"

step "Commit + push (this commit IS the release; reverting it IS the rollback)"
# Commit only the overlay file, whatever else may be staged.
git -C "$REPO_ROOT" commit -m "release($SERVICE): $ENV -> $VERSION" -- "platform/deploy/overlays/$ENV/kustomization.yaml"
git -C "$REPO_ROOT" push
SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
ok "pushed ${SHA:0:8}"

step "Argo CD sync + rollout"
argocd_sync "boutique-$ENV" "$SHA"   # this exact commit, without waiting for polling
# 600s covers the sync retry backoff (see platform/gitops/applications.yaml).
wait_app_at_revision "boutique-$ENV" "$SHA" 600 || die "Argo CD did not reach ${SHA:0:8}"
verify_own_service "$ENV" "$SERVICE" "$VERSION" || die "release not verified"
k -n "$NS" get pods -l "app=$SERVICE" -o custom-columns='POD:.metadata.name,IMAGE:.spec.containers[0].image,READY:.status.containerStatuses[0].ready'
