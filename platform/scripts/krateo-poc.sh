#!/usr/bin/env bash
# Minimal Krateo PoC: Online Boutique as a self-service API.
#
#   chart (platform/krateo/boutique-service) --CompositionDefinition-->
#   Krateo core-provider generates CRD BoutiqueService + a dedicated controller
#   --BoutiqueService instance--> Helm release = Argo CD Application
#   --> Argo CD deploys the platform overlay into boutique-<name>-<env>.
#
# Usage: platform/scripts/krateo-poc.sh package   # build the chart .tgz (commit + push it)
#        platform/scripts/krateo-poc.sh install   # core-provider + definition + one instance
#        platform/scripts/krateo-poc.sh status
#        platform/scripts/krateo-poc.sh cleanup   # remove the instance (and its workload)
#
# Only Krateo's core-provider (+ chart-inspector) is installed, not the whole
# PlatformOps suite (portal, authn, events, finops): it is the piece that
# turns a chart into an API, and it fits in the demo VM.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need helm kubectl git

CHART_DIR="$REPO_ROOT/platform/krateo/boutique-service"
DIST="$REPO_ROOT/platform/krateo/dist"
CHART_VERSION="$(awk '/^version:/{print $2}' "$CHART_DIR/Chart.yaml")"
TGZ="boutique-service-${CHART_VERSION}.tgz"
INSTANCE_NS="boutique-team-a-dev"

raw_chart_url() {
  # https://github.com/u/r.git -> https://raw.githubusercontent.com/u/r/main/...
  local r; r="$(repo_url)"; r="${r%.git}"; r="${r/github.com/raw.githubusercontent.com}"
  echo "${r}/main/platform/krateo/dist/${TGZ}"
}

case "${1:-}" in
  package)
    step "helm lint + package"
    helm lint "$CHART_DIR"
    mkdir -p "$DIST"
    helm package "$CHART_DIR" -d "$DIST"
    ok "$DIST/$TGZ"
    echo "    Commit and push it, Krateo downloads it from: $(raw_chart_url)"
    echo "    (production: helm push $DIST/$TGZ oci://ghcr.io/<org>/charts and use an oci:// URL)"
    ;;

  install)
    REPO="$(repo_url)"
    curl -fsI "$(raw_chart_url)" >/dev/null || die "chart not reachable at $(raw_chart_url): run '$0 package', commit and push first"

    step "Krateo core-provider (includes chart-inspector)"
    helm repo add krateo https://charts.krateo.io >/dev/null 2>&1 || true
    helm repo update krateo >/dev/null
    helm --kube-context "$KUBE_CONTEXT" upgrade --install krateo-core-provider krateo/core-provider \
      -n krateo-system --create-namespace --wait --timeout 10m ${KRATEO_CORE_PROVIDER_VERSION:+--version "$KRATEO_CORE_PROVIDER_VERSION"}
    ok "core-provider running"

    step "Argo CD guardrail for self-service instances (AppProject boutique-selfservice)"
    sed "s#https://github.com/YOUR_GITHUB_USER/microservices-demo.git#${REPO}#g" \
      "$REPO_ROOT/platform/krateo/appproject-selfservice.yaml" | k apply -f -

    step "CompositionDefinition boutique-service -> generated CRD + controller"
    sed "s#oci://ghcr.io/YOUR_GITHUB_USER/charts/boutique-service#$(raw_chart_url)#" \
      "$REPO_ROOT/platform/krateo/krateo/compositiondefinition.yaml" | k apply -f -
    k -n krateo-system wait compositiondefinition boutique-service --for condition=Ready=True --timeout=600s
    k get crd | grep composition.krateo.io || true

    step "Prerequisite owned by the platform: secret in the instance namespace"
    "$REPO_ROOT/platform/scripts/create-secrets.sh" "$INSTANCE_NS"

    step "A consumer team requests an instance (this is the whole 'ticket')"
    cat <<YAML | tee /dev/stderr | k apply -f -
apiVersion: composition.krateo.io/v${CHART_VERSION//./-}
kind: BoutiqueService
metadata:
  name: team-a-dev
  namespace: krateo-system
spec:
  service:
    name: team-a
    owner: team-a
    tier: bronze
  environment: dev
  frontend:
    version: 1.0.0
  git:
    repoURL: ${REPO}
    targetRevision: main
YAML
    "$0" status
    ;;

  status)
    step "Krateo"
    k -n krateo-system get compositiondefinitions || true
    k -n krateo-system get boutiqueservices 2>/dev/null || warn "CRD not generated yet"
    step "Argo CD Application created by the composition"
    k -n argocd get applications -l app.kubernetes.io/managed-by=krateo || true
    step "Workload"
    k -n "$INSTANCE_NS" get pods 2>/dev/null || warn "namespace $INSTANCE_NS not created yet"
    IP="$(gateway_ip)"
    [[ -n "$IP" ]] && echo "    curl -s --resolve team-a.dev.boutique.local:80:$IP http://team-a.dev.boutique.local/_healthz"
    ;;

  cleanup)
    step "Deleting BoutiqueService team-a-dev (Argo CD finalizer removes the workload)"
    k -n krateo-system delete boutiqueservice team-a-dev --ignore-not-found --wait=true
    k delete ns "$INSTANCE_NS" --ignore-not-found
    ok "done (core-provider left installed; helm -n krateo-system uninstall krateo-core-provider to remove it)"
    ;;

  *) die "usage: $0 package|install|status|cleanup" ;;
esac
