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
#          KIND_NODE_CPUS  CPU cap for the kind node container (0..vCPUs, at most one decimal; default vCPUs - 0.5, no cap with <= 2 vCPUs; 0 = no cap)
# Re-running is safe: every step checks what already exists.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

need docker kind kubectl helm git curl openssl ss

# Pinned versions, verified together on 2026-11-18 (README "Pinned versions").
# Override per run with the same variable, e.g. KPS_VERSION=94.0.0. Unpinned
# charts made Kyverno 1.20 arrive unannounced and refuse the legacy policies.
CPK_VERSION="${CPK_VERSION:-v0.12.0}"                       # cloud-provider-kind image
METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-3.14.0}"  # chart (app 0.9.0)
KPS_VERSION="${KPS_VERSION:-93.3.1}"                        # kube-prometheus-stack chart
KYVERNO_VERSION="${KYVERNO_VERSION:-3.10.0}"                # chart (app v1.20.0)
ARGOCD_VERSION="${ARGOCD_VERSION:-10.18.0}"                 # argo-cd chart (app v3.6.1)

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
# Compared in MiB against MemTotal, which is below the RAM given to the VM
# (the kernel keeps some at boot: 11 GiB assigned -> 10,900 MiB here).
mem_mib="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)"
(( mem_mib >= 10240 )) || {
  warn "only ${mem_mib} MiB of usable memory (MemTotal)"
  warn "It is recommended to configure the system to provide at least 10 GiB of usable memory (MemTotal). Memory for crashdump and reserved by the kernel is not part of it, therefore, depending on the configuration of these latter, the system is recommended to have at least 11 GiB of RAM."
}
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

# Cap the node container at (vCPUs - 0.5): without a cap, pods can take every
# CPU and freeze the host (seen on the first real bootstrap: desktop
# unresponsive for minutes). Applied on every run, so it also fixes existing
# clusters. 0.5 vCPU stays outside the cap for the VM (desktop, dockerd, the
# Gateway's Envoy container, kernel): measured ~360m at rest. The kubelet
# reservations (platform/kind/cluster.yaml) must match: allocatable =
# vCPUs - systemReserved (the 0.5 left out) - kubeReserved.
# With 2 vCPUs or fewer the default is no cap: too little to run two
# environments, monitoring, Argo CD and Kyverno.
host_cpus="$(nproc)"
default_cpus="$(( host_cpus > 2 ? host_cpus - 1 : host_cpus )).$(( host_cpus > 2 ? 5 : 0 ))"
node_cpus="${KIND_NODE_CPUS:-$default_cpus}"
# An integer or one decimal digit (3, 3.5). No leading zeros. Compared in
# millicores because bash arithmetic is integer-only (and would read "08" as
# octal).
if ! [[ "$node_cpus" =~ ^(0|[1-9][0-9]*)(\.[0-9])?$ ]]; then
  die "KIND_NODE_CPUS must be a number with at most one decimal, 0 to ${host_cpus} (got '${node_cpus}')"
fi
cpu_int="${node_cpus%.*}"; cpu_dec=0
[[ "$node_cpus" == *.* ]] && cpu_dec="${node_cpus#*.}"
node_mcpu=$(( cpu_int * 1000 + cpu_dec * 100 ))
if (( node_mcpu > host_cpus * 1000 )); then
  die "KIND_NODE_CPUS must be a number with at most one decimal, 0 to ${host_cpus} (got '${node_cpus}')"
fi
if (( node_mcpu == 0 || node_mcpu == host_cpus * 1000 )); then
  # "docker update --cpus 0" leaves an existing cap unchanged: set it to all CPUs.
  docker update --cpus "$host_cpus" "${CLUSTER_NAME}-control-plane" >/dev/null
  warn "node container not capped: it may use all ${host_cpus} CPUs"
else
  docker update --cpus "$node_cpus" "${CLUSTER_NAME}-control-plane" >/dev/null
  ok "node container capped at ${node_cpus} of ${host_cpus} CPUs (override: KIND_NODE_CPUS, 0 = no cap)"
fi

step "cloud-provider-kind (LoadBalancer IPs + Gateway API controller)"
# grep >/dev/null, not grep -q, after a pipe with pipefail (ai-usage §3.6).
if docker ps --format '{{.Names}}' | grep -x cloud-provider-kind >/dev/null; then
  ok "already running"
else
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

# After a host reboot cloud-provider-kind listens for xDS on a new random
# port, but Docker restarts the existing Envoy gateway containers with the old
# port baked into their command: Envoy gets no listeners and the Gateway is
# unreachable (seen for real). Remove stale containers: cloud-provider-kind
# recreates them with the current port on its next Gateway sync (~1 min).
xds_port=""
for _ in $(seq 1 12); do xds_port="$(cpk_xds_port)"; [[ -n "$xds_port" ]] && break; sleep 5; done
if [[ -z "$xds_port" ]]; then
  warn "cannot read the cloud-provider-kind xDS port: gateway containers not checked"
else
  stale=0
  for gw in $(docker ps -a --format '{{.Names}}' | grep '^kindccm-gw-' || true); do
    gw_port="$(gw_xds_port "$gw")"
    if [[ "$gw_port" != "$xds_port" ]]; then
      warn "$gw points to xDS port ${gw_port:-?}, cloud-provider-kind listens on $xds_port: removing it"
      docker rm -f "$gw" >/dev/null; stale=$((stale + 1))
    fi
  done
  if (( stale > 0 )); then
    echo "    waiting for cloud-provider-kind to recreate the gateway container(s)..."
    for _ in $(seq 1 36); do   # up to 3 min
      gw="$(docker ps --format '{{.Names}}' | grep '^kindccm-gw-' | head -1 || true)"
      [[ -n "$gw" && "$(gw_xds_port "$gw")" == "$xds_port" ]] && break
      sleep 5
    done
    [[ -n "$gw" && "$(gw_xds_port "$gw")" == "$xds_port" ]] \
      || die "gateway container not recreated with xDS port $xds_port: check 'docker logs cloud-provider-kind'"
    ok "gateway container $gw recreated (xDS port $xds_port)"
  else
    ok "gateway container(s) use the current xDS port $xds_port"
  fi
fi

step "Helm add-ons"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update >/dev/null
VALUES="$REPO_ROOT/platform/addons/values"
H=(helm --kube-context "$KUBE_CONTEXT" upgrade --install --wait --timeout 10m)

"${H[@]}" metrics-server metrics-server/metrics-server -n kube-system \
  -f "$VALUES/metrics-server.yaml" --version "$METRICS_SERVER_VERSION" >/dev/null
ok "metrics-server"

# Grafana admin password: generated once, then reused from the existing Secret.
GRAFANA_PW="$(k -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || true)"
[[ -n "$GRAFANA_PW" ]] || GRAFANA_PW="$(openssl rand -hex 16)"
"${H[@]}" kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring --create-namespace \
  -f "$VALUES/kube-prometheus-stack.yaml" --set-string grafana.adminPassword="$GRAFANA_PW" \
  --version "$KPS_VERSION" >/dev/null
ok "kube-prometheus-stack"

"${H[@]}" kyverno kyverno/kyverno -n kyverno --create-namespace \
  -f "$VALUES/kyverno.yaml" --version "$KYVERNO_VERSION" >/dev/null
ok "kyverno"

"${H[@]}" argocd argo/argo-cd -n argocd --create-namespace \
  -f "$VALUES/argocd.yaml" --version "$ARGOCD_VERSION" >/dev/null
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
  manifest="$(render_repo_url "$REPO_ROOT/platform/gitops/$f" "$REPO")"
  k apply -f - <<<"$manifest" >/dev/null
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
  # Exact line match: after a VM reboot Docker can hand the node and the
  # gateway container each other's IP (seen for real: 172.18.0.2 <-> .3).
  if grep -Fxq "$HOSTS_LINE # boutique-challenge" /etc/hosts; then
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
