# shellcheck shell=bash
# Shared helpers for the platform scripts. Source it, don't run it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-boutique}"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"
# shellcheck disable=SC2034  # used by the scripts that source this file
ENVS=(dev prod)

if [[ -t 1 ]]; then
  C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_OFF=$'\033[0m'
else
  C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_OFF=""
fi

step() { echo; echo "${C_BLUE}==> $*${C_OFF}"; }
ok()   { echo "${C_GREEN}  ✔ $*${C_OFF}"; }
warn() { echo "${C_YELLOW}  ! $*${C_OFF}" >&2; }
die()  { echo "${C_RED}  ✘ $*${C_OFF}" >&2; exit 1; }

need() {
  local missing=0
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || { warn "missing command: $bin"; missing=1; }
  done
  [[ $missing -eq 0 ]] || die "install the missing tools (platform/scripts/install-tools.sh) and retry"
}

# kubectl pinned to the challenge cluster, so a wrong current-context can
# never point these scripts at another cluster.
k() { kubectl --context "$KUBE_CONTEXT" "$@"; }

ns_for() { echo "boutique-$1"; }

host_for() {
  case "$1" in
    dev)  echo "dev.boutique.local" ;;
    prod) echo "boutique.local" ;;
    *)    die "unknown environment: $1 (use dev or prod)" ;;
  esac
}

# xDS port cloud-provider-kind listens on in its *current* run (it picks a
# random port at every start). Logs are read only since the container's last
# start: older runs' lines are still in "docker logs". Empty if not logged yet.
cpk_xds_port() {
  local since
  since="$(docker inspect -f '{{.State.StartedAt}}' cloud-provider-kind 2>/dev/null)" || return 0
  docker logs --since "$since" cloud-provider-kind 2>&1 \
    | sed -n 's/.*"XDS management server listening".* port=\([0-9][0-9]*\).*/\1/p' | tail -1
}

# xDS port baked into an Envoy gateway container created by
# cloud-provider-kind: the first port_value after "xds_cluster" in the config
# its command writes (the admin port comes later in the same config).
gw_xds_port() { # gw_xds_port <container>
  docker inspect -f '{{index .Config.Cmd 2}}' "$1" 2>/dev/null \
    | sed 's/\\n/\n/g' | awk '/xds_cluster/{f=1} f && /port_value:/{print $2; exit}'
}

gateway_ip() {
  k -n gateway-infra get gateway boutique-gateway \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true
}

# Repo URL used by Argo CD: $GIT_REPO_URL or the "origin" remote, as https.
repo_url() {
  local url="${GIT_REPO_URL:-}"
  if [[ -z "$url" ]]; then
    url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  fi
  [[ -n "$url" ]] || die "cannot detect the Git repo URL: set GIT_REPO_URL=https://github.com/<user>/microservices-demo.git"
  # git@github.com:user/repo.git -> https://github.com/user/repo.git
  if [[ "$url" =~ ^git@([^:]+):(.+)$ ]]; then
    url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  fi
  [[ "$url" == *.git ]] || url="${url}.git"
  echo "$url"
}

# Ask Argo CD to sync an Application now (same as "Sync" in the UI), without
# needing the argocd CLI or a login.
argocd_sync() {
  local app="$1"
  k -n argocd patch application "$app" --type merge \
    -p '{"operation":{"initiatedBy":{"username":"platform-script"},"sync":{"revision":"HEAD","prune":true}}}' >/dev/null
}

wait_app_healthy() {
  local app="$1" timeout="${2:-600}" waited=0 sync health
  while true; do
    sync="$(k -n argocd get application "$app" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(k -n argocd get application "$app" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
      ok "$app: Synced / Healthy"
      return 0
    fi
    if (( waited >= timeout )); then
      warn "$app: still $sync / $health after ${timeout}s"
      return 1
    fi
    sleep 10; waited=$((waited + 10))
    echo "    ... $app: ${sync:-?} / ${health:-?} (${waited}s)"
  done
}
