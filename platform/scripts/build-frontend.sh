#!/usr/bin/env bash
# Builds the frontend image from this fork and side-loads it into kind.
#
# Usage: platform/scripts/build-frontend.sh <version>      e.g. 1.1.0
#
# The image is tagged boutique/frontend:<version>, the name the Kustomize
# overlays use. Side-loading (kind load) avoids needing a registry locally;
# CI builds the same Dockerfile and pushes to GHCR (.github/workflows).
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need docker kind

VERSION="${1:?usage: $0 <version>   e.g. 1.1.0}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be semver X.Y.Z (got '$VERSION')"
IMAGE="boutique/frontend:${VERSION}"

step "docker build $IMAGE"
docker build \
  --build-arg APP_VERSION="$VERSION" \
  --label org.opencontainers.image.revision="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)" \
  -t "$IMAGE" "$REPO_ROOT/src/frontend"
ok "built $(docker image inspect "$IMAGE" --format '{{.Id}}' | cut -c8-19) ($(docker image inspect "$IMAGE" --format '{{.Size}}' | awk '{printf "%.0f MB", $1/1024/1024}'))"

step "kind load $IMAGE"
kind load docker-image "$IMAGE" --name "$CLUSTER_NAME"
ok "available on the cluster node (imagePullPolicy IfNotPresent)"
