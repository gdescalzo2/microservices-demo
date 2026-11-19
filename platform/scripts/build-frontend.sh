#!/usr/bin/env bash
# Builds the frontend image from this fork and side-loads it into kind.
#
# Usage: platform/scripts/build-frontend.sh <version>      e.g. 1.1.0
#        FORCE=1 platform/scripts/build-frontend.sh <version>   rebuild and reload
#
# The image is tagged boutique/frontend:<version>, the name the Kustomize
# overlays use. Side-loading (kind load) avoids needing a registry locally;
# CI builds the same Dockerfile and pushes to GHCR (.github/workflows).
#
# A version is immutable: if the tag is already on the kind node, nothing is
# built or loaded; if it is only in the local Docker, it is loaded as is.
# Rebuilding gives a new image ID even from the same commit with every step
# cached (measured: 9.9.9 rebuilt at the same commit, c73000a5 -> e3d51179),
# and loading it would silently re-point the tag on the node:
# a pod recreated later would run a different image than its siblings under
# the same version (seen for real, ai-usage §3.23).
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need docker kind

VERSION="${1:?usage: $0 <version>   e.g. 1.1.0}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be semver X.Y.Z (got '$VERSION')"
FORCE="${FORCE:-0}"
[[ "$FORCE" =~ ^[01]$ ]] || die "FORCE must be 0 or 1 (got '$FORCE')"
IMAGE="boutique/frontend:${VERSION}"

if [[ "$FORCE" == "0" ]] && image_on_node "$IMAGE"; then
  ok "$IMAGE already on the kind node: not rebuilt, not reloaded (FORCE=1 to replace it)"
  exit 0
fi

if [[ "$FORCE" == "0" ]] && docker image inspect "$IMAGE" >/dev/null 2>&1; then
  ok "$IMAGE already built locally: not rebuilt (FORCE=1 to rebuild)"
else
  step "docker build $IMAGE"
  docker build \
    --build-arg APP_VERSION="$VERSION" \
    --label org.opencontainers.image.revision="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)" \
    -t "$IMAGE" "$REPO_ROOT/src/frontend"
  ok "built $(docker image inspect "$IMAGE" --format '{{.Id}}' | cut -c8-19) ($(docker image inspect "$IMAGE" --format '{{.Size}}' | awk '{printf "%.0f MB", $1/1024/1024}'))"
fi

step "kind load $IMAGE"
kind load docker-image "$IMAGE" --name "$CLUSTER_NAME"
ok "available on the cluster node (imagePullPolicy IfNotPresent)"
