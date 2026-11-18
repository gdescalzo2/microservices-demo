#!/usr/bin/env bash
# GitOps release of a new frontend version to one environment:
#   build + load image -> change the tag in the overlay -> commit + push
#   -> Argo CD syncs -> rolling update (maxUnavailable 0).
#
# Usage: platform/scripts/release.sh <dev|prod> <version>     e.g. dev 1.1.0
#        SKIP_BUILD=1 platform/scripts/release.sh prod 1.1.0  # image already built (promotion)
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need git kubectl kustomize docker curl jq

ENV="${1:?usage: $0 <dev|prod> <version>}"; VERSION="${2:?usage: $0 <dev|prod> <version>}"
NS="$(ns_for "$ENV")"; OVERLAY="$REPO_ROOT/platform/deploy/overlays/$ENV"
[[ -d "$OVERLAY" ]] || die "no overlay for '$ENV'"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be semver X.Y.Z (got '$VERSION')"

[[ -z "$(git -C "$REPO_ROOT" status --porcelain -- platform/deploy)" ]] \
  || die "uncommitted changes under platform/deploy: commit or stash them first"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  "$REPO_ROOT/platform/scripts/build-frontend.sh" "$VERSION"
else
  # Promotion: the image must already be on the kind node, or the rollout
  # would end in ImagePullBackOff (there is no registry to pull from).
  # grep >/dev/null, not grep -q: with pipefail, -q exits early and the
  # SIGPIPE fails the pipeline even on a match (ai-usage §3.6).
  docker exec "${CLUSTER_NAME}-control-plane" crictl images -o json \
    | grep "\"docker.io/boutique/frontend:${VERSION}\"" >/dev/null \
    || die "boutique/frontend:${VERSION} is not on the kind node: build it first (build-frontend.sh ${VERSION})"
  ok "boutique/frontend:${VERSION} already on the kind node"
fi

step "Overlay $ENV: boutique/frontend -> $VERSION"
CURRENT="$(cd "$OVERLAY" && kustomize build . | awk '/image: boutique\/frontend:/{print $2; exit}')"
echo "    current: $CURRENT"
(cd "$OVERLAY" && kustomize edit set image "boutique/frontend=boutique/frontend:${VERSION}")
git -C "$REPO_ROOT" --no-pager diff -- "platform/deploy/overlays/$ENV"

step "Commit + push (this commit IS the release; reverting it IS the rollback)"
# Commit only the overlay file, whatever else may be staged.
git -C "$REPO_ROOT" commit -m "release(frontend): $ENV -> $VERSION" -- "platform/deploy/overlays/$ENV/kustomization.yaml"
git -C "$REPO_ROOT" push
SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
ok "pushed ${SHA:0:8}"

step "Argo CD sync + rollout"
argocd_sync "boutique-$ENV" "$SHA"   # this exact commit, without waiting for polling
# 600s covers the sync retry backoff (see platform/gitops/applications.yaml).
wait_app_at_revision "boutique-$ENV" "$SHA" 600 || die "Argo CD did not reach ${SHA:0:8}"
verify_frontend "$ENV" "$VERSION" || die "release not verified"
k -n "$NS" get pods -l app=frontend -o custom-columns='POD:.metadata.name,IMAGE:.spec.containers[0].image,READY:.status.containerStatuses[0].ready'
