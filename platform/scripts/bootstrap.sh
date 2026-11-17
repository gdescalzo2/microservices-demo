#!/usr/bin/env bash
# One-shot, idempotent setup of the whole local platform:
#   kind cluster -> cloud-provider-kind (LoadBalancer + Gateway API)
#   -> metrics-server, kube-prometheus-stack, Kyverno, Argo CD (Helm)
#   -> frontend image build + side-load -> Redis secrets
#   -> Argo CD projects/applications (from then on, Git drives everything).
#
# Usage:   platform/scripts/bootstrap.sh
# Env:     GIT_REPO_URL  repo Argo CD will track (default: git remote "origin")
#          SKIP_BUILD=1  do not build the frontend image
#          KIND_NODE_CPUS  CPU cap for the kind node container (default: vCPUs - 1, 0 = no cap)
# Re-running is safe: every step checks what already exists.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

need docker kind kubectl helm git curl openssl

REPO="$(repo_url)"
[[ "$REPO" != *YOUR_GITHUB_USER* ]] || die "GIT_REPO_URL still has the placeholder: set it to your fork"

step "Host checks"
inotify_watches="$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)"
inotify_instances="$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)"
if (( inotify_watches < 524288 || inotify_instances < 512 )); then
  warn "low inotify limits (watches=$inotify_watches, instances=$inotify_instances): pods may fail with 'too many open files'"
  warn "fix: sudo sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512"
else
  ok "inotify limits"
fi
mem_gb="$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)"
(( mem_gb >= 8 )) || warn "only ${mem_gb} GB RAM: 10 GB recommended (two full environments + monitoring)"
ok "repo tracked by Argo CD: $REPO"

step "kind cluster '$CLUSTER_NAME'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  ok "already exists"
else
  kind create cluster --config "$REPO_ROOT/platform/kind/cluster.yaml" --wait 120s
fi
# kind labels the control-plane node as excluded from load balancers; on a
# single-node cluster that would leave the Gateway without backends.
k label node "${CLUSTER_NAME}-control-plane" node.kubernetes.io/exclude-from-external-load-balancers- >/dev/null 2>&1 || true

# Cap the node container at (vCPUs - 1): without it, pods can take every CPU
# and freeze the host (seen on the first real bootstrap: desktop unresponsive
# for minutes). Applied on every run, so it also fixes existing clusters.
host_cpus="$(nproc)"
node_cpus="${KIND_NODE_CPUS:-$(( host_cpus > 2 ? host_cpus - 1 : host_cpus ))}"
if [[ "$node_cpus" == "0" ]]; then
  # "docker update --cpus 0" leaves an existing cap unchanged: set it to all CPUs.
  docker update --cpus "$host_cpus" "${CLUSTER_NAME}-control-plane" >/dev/null
  warn "KIND_NODE_CPUS=0: node container may use all ${host_cpus} CPUs"
else
  docker update --cpus "$node_cpus" "${CLUSTER_NAME}-control-plane" >/dev/null
  ok "node container capped at ${node_cpus} of ${host_cpus} CPUs (override: KIND_NODE_CPUS, 0 = no cap)"
fi

step "cloud-provider-kind (LoadBalancer IPs + Gateway API controller)"
if docker ps --format '{{.Names}}' | grep -qx cloud-provider-kind; then
  ok "already running"
else
  CPK_VERSION="${CPK_VERSION:-$(basename "$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/kubernetes-sigs/cloud-provider-kind/releases/latest)")}"
  docker rm -f cloud-provider-kind >/dev/null 2>&1 || true
  docker run -d --name cloud-provider-kind --restart unless-stopped --network host \
    -v /var/run/docker.sock:/var/run/docker.sock \
    "registry.k8s.io/cloud-provider-kind/cloud-controller-manager:${CPK_VERSION}" >/dev/null
  ok "started ${CPK_VERSION}"
fi
echo "    waiting for Gateway API CRDs (installed by cloud-provider-kind)..."
for _ in $(seq 1 60); do
  k get crd httproutes.gateway.networking.k8s.io >/dev/null 2>&1 && break
  sleep 5
done
k wait --for condition=Established crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io --timeout=60s >/dev/null
ok "Gateway API CRDs ready"

step "Helm add-ons"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update >/dev/null
VALUES="$REPO_ROOT/platform/addons/values"
H=(helm --kube-context "$KUBE_CONTEXT" upgrade --install --wait --timeout 10m)

"${H[@]}" metrics-server metrics-server/metrics-server -n kube-system \
  -f "$VALUES/metrics-server.yaml" ${METRICS_SERVER_VERSION:+--version "$METRICS_SERVER_VERSION"} >/dev/null
ok "metrics-server"

# Grafana admin password: generated once, then reused from the existing Secret.
GRAFANA_PW="$(k -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || true)"
[[ -n "$GRAFANA_PW" ]] || GRAFANA_PW="$(openssl rand -hex 16)"
"${H[@]}" kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring --create-namespace \
  -f "$VALUES/kube-prometheus-stack.yaml" --set-string grafana.adminPassword="$GRAFANA_PW" \
  ${KPS_VERSION:+--version "$KPS_VERSION"} >/dev/null
ok "kube-prometheus-stack"

"${H[@]}" kyverno kyverno/kyverno -n kyverno --create-namespace \
  -f "$VALUES/kyverno.yaml" ${KYVERNO_VERSION:+--version "$KYVERNO_VERSION"} >/dev/null
ok "kyverno"

"${H[@]}" argocd argo/argo-cd -n argocd --create-namespace \
  -f "$VALUES/argocd.yaml" ${ARGOCD_VERSION:+--version "$ARGOCD_VERSION"} >/dev/null
ok "argo-cd"

step "Frontend image (our fork, with /metrics)"
if [[ "${SKIP_BUILD:-0}" == "1" ]]; then
  warn "SKIP_BUILD=1: not building"
else
  "$REPO_ROOT/platform/scripts/build-frontend.sh" 1.0.0
fi

step "Secrets (generated here, never committed)"
"$REPO_ROOT/platform/scripts/create-secrets.sh"

step "Argo CD projects and applications"
for f in projects.yaml applications.yaml; do
  sed "s#https://github.com/YOUR_GITHUB_USER/microservices-demo.git#${REPO}#g" \
    "$REPO_ROOT/platform/gitops/$f" | k apply -f - >/dev/null
done
ok "applied (tracking ${REPO}, branch main)"

step "Waiting for Argo CD to sync (first time pulls ~12 images: can take 10+ minutes)"
wait_app_healthy platform-config 300 || true
wait_app_healthy boutique-dev 1200 || true
wait_app_healthy boutique-prod 1200 || true

step "Gateway address and /etc/hosts"
IP=""
for _ in $(seq 1 30); do IP="$(gateway_ip)"; [[ -n "$IP" ]] && break; sleep 5; done
if [[ -z "$IP" ]]; then
  warn "Gateway has no address yet: check 'docker logs cloud-provider-kind'"
else
  ok "Gateway IP: $IP"
  HOSTS_LINE="$IP $(host_for dev) $(host_for prod)"
  if grep -q "# boutique-challenge" /etc/hosts && grep -q "^$IP " /etc/hosts; then
    ok "/etc/hosts already up to date"
  else
    echo "    /etc/hosts needs: $HOSTS_LINE"
    read -r -p "    Add/update it now with sudo? [y/N] " ans || ans=n
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      sudo sed -i '/# boutique-challenge$/d' /etc/hosts
      echo "$HOSTS_LINE # boutique-challenge" | sudo tee -a /etc/hosts >/dev/null
      ok "/etc/hosts updated"
    fi
  fi
fi

step "Done"
cat <<EOF
  Shop (dev):   http://$(host_for dev)
  Shop (prod):  http://$(host_for prod)

  Argo CD:      kubectl -n argocd port-forward svc/argocd-server 8080:80   -> http://localhost:8080
                user admin, password:
                kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
  Grafana:      kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80 -> http://localhost:3000
                user admin, password:
                kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
  Prometheus:   kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -> http://localhost:9090/alerts

  Next:         platform/scripts/smoke-test.sh dev && platform/scripts/smoke-test.sh prod
EOF
