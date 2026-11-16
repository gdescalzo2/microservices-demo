#!/usr/bin/env bash
# GitOps release of a new frontend version to one environment:
#   build + load image -> change the tag in the overlay -> commit + push
#   -> Argo CD syncs -> rolling update (maxUnavailable 0).
#
# Usage: platform/scripts/release.sh <dev|prod> <version>     e.g. dev 1.1.0
#        SKIP_BUILD=1 platform/scripts/release.sh prod 1.1.0  # image already built (promotion)
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need git kubectl kustomize

ENV="${1:?usage: $0 <dev|prod> <version>}"; VERSION="${2:?usage: $0 <dev|prod> <version>}"
NS="$(ns_for "$ENV")"; OVERLAY="$REPO_ROOT/platform/deploy/overlays/$ENV"
[[ -d "$OVERLAY" ]] || die "no overlay for '$ENV'"

[[ -z "$(git -C "$REPO_ROOT" status --porcelain -- platform/deploy)" ]] \
  || die "uncommitted changes under platform/deploy: commit or stash them first"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  "$REPO_ROOT/platform/scripts/build-frontend.sh" "$VERSION"
fi

step "Overlay $ENV: boutique/frontend -> $VERSION"
CURRENT="$(cd "$OVERLAY" && kustomize build . | awk '/image: boutique\/frontend:/{print $2; exit}')"
echo "    current: $CURRENT"
(cd "$OVERLAY" && kustomize edit set image "boutique/frontend=boutique/frontend:${VERSION}")
git -C "$REPO_ROOT" --no-pager diff -- "platform/deploy/overlays/$ENV"

step "Commit + push (this commit IS the release; reverting it IS the rollback)"
git -C "$REPO_ROOT" add "platform/deploy/overlays/$ENV/kustomization.yaml"
git -C "$REPO_ROOT" commit -m "release(frontend): $ENV -> $VERSION"
git -C "$REPO_ROOT" push
ok "pushed $(git -C "$REPO_ROOT" rev-parse --short HEAD)"

step "Argo CD sync + rollout"
argocd_sync "boutique-$ENV"   # don't wait for the 60s polling interval
sleep 5
k -n "$NS" rollout status deploy/frontend --timeout=300s
wait_app_healthy "boutique-$ENV" 300
k -n "$NS" get pods -l app=frontend -o custom-columns='POD:.metadata.name,IMAGE:.spec.containers[0].image,READY:.status.containerStatuses[0].ready'
IP="$(gateway_ip)"; HOST="$(host_for "$ENV")"
echo "    X-App-Version: $(curl -sI --resolve "${HOST}:80:${IP}" "http://${HOST}/" | awk -F': ' 'tolower($1)=="x-app-version"{print $2}')"
