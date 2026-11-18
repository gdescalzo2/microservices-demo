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

# Sets the newTag of one image entry in a kustomization.yaml, changing only
# that value: indentation, comments and every other line stay as they are.
# Not "kustomize edit set image": it rewrites the whole file in its own format
# (indentation, comment placement, dropped default fields; seen for real).
# Fails, leaving the file untouched, unless exactly one entry named <image>
# exists and exactly one newTag line in it was changed. The newTag must come
# after "name:" in the entry (the layout used in this repo).
set_image_tag() { # set_image_tag <kustomization.yaml> <image name> <tag>
  local file="$1" image="$2" tag="$3" tmp
  tmp="$(mktemp)"
  if ! awk -v image="$image" -v tag="$tag" '
    {
      line = $0
      if (line ~ /^[ ]*(- )?name:[ ]*/) {          # a "name:" key, list item or not
        v = line
        sub(/^[ ]*(- )?name:[ ]*/, "", v); sub(/[ ]*(#.*)?$/, "", v); gsub(/"/, "", v)
        if (v == image) { inblk = 1; found++; print line; next }
        if (inblk) inblk = 0
      }
      if (inblk && line ~ /^[ ]*- /) inblk = 0      # next list item
      if (inblk && line ~ /^[^ #]/) inblk = 0       # back to a top-level key
      if (inblk && line ~ /^[ ]*newTag:/) {
        pre = line;  sub(/newTag:.*/, "", pre)                          # indentation
        rest = line; sub(/^[ ]*newTag:[ ]*("[^"]*"|[^ #]+)/, "", rest)  # trailing comment
        q = (line ~ /newTag:[ ]*"/) ? "\"" : ""                         # keep quoting
        print pre "newTag: " q tag q rest; changed++; inblk = 0; next
      }
      print line
    }
    END {
      if (found != 1 || changed != 1) {
        printf "set_image_tag: %d entries named %s, %d newTag lines changed (expected 1 and 1)\n", found, image, changed > "/dev/stderr"
        exit 3
      }
    }' "$file" > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  cat "$tmp" > "$file"   # cat, not mv: keeps the original file's permissions
  rm -f "$tmp"
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
# An explicit sync operation does not inherit spec.syncPolicy.retry: it gets
# the same retry policy here (see platform/gitops/applications.yaml).
argocd_sync() { # argocd_sync <app> [revision]  (default HEAD of the tracked branch)
  local app="$1" rev="${2:-HEAD}"
  k -n argocd patch application "$app" --type merge \
    -p "{\"operation\":{\"initiatedBy\":{\"username\":\"platform-script\"},\"sync\":{\"revision\":\"${rev}\",\"prune\":true},\"retry\":{\"limit\":5,\"backoff\":{\"duration\":\"5s\",\"factor\":2,\"maxDuration\":\"3m\"}}}}" >/dev/null
}

# Waits until Argo CD reports the app Synced *at this exact commit* and
# Healthy. wait_app_healthy alone can succeed on the previous revision right
# after a push (Synced/Healthy before Argo CD has seen the new commit).
wait_app_at_revision() { # wait_app_at_revision <app> <full-sha> [timeout]
  local app="$1" sha="$2" timeout="${3:-300}" waited=0 rev sync health
  while true; do
    rev="$(k -n argocd get application "$app" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
    sync="$(k -n argocd get application "$app" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(k -n argocd get application "$app" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    if [[ "$rev" == "$sha" && "$sync" == "Synced" && "$health" == "Healthy" ]]; then
      ok "$app: Synced / Healthy at ${sha:0:8}"
      return 0
    fi
    if (( waited >= timeout )); then
      warn "$app: ${sync:-?} / ${health:-?} at ${rev:0:8}, expected ${sha:0:8}, after ${timeout}s"
      return 1
    fi
    sleep 5; waited=$((waited + 5))
    echo "    ... $app: ${sync:-?} / ${health:-?} at ${rev:0:8} (${waited}s)"
  done
}

# Fails unless the frontend of <env> runs <version> end to end: Deployment
# image tag, every frontend pod after the rollout, and the X-App-Version
# header served through the Gateway.
verify_frontend() { # verify_frontend <env> <version>
  local env="$1" version="$2" ns host ip spec_image pods_ok pods_total pods_bad header
  ns="$(ns_for "$env")"; host="$(host_for "$env")"; ip="$(gateway_ip)"
  spec_image="$(k -n "$ns" get deploy frontend -o jsonpath='{.spec.template.spec.containers[0].image}')"
  [[ "$spec_image" == "boutique/frontend:${version}" ]] \
    || { warn "Deployment frontend image is '$spec_image', expected boutique/frontend:${version}"; return 1; }
  k -n "$ns" rollout status deploy/frontend --timeout=300s || return 1
  # Running pods that are not being deleted (terminating pods of the old
  # ReplicaSet still report phase Running). At least one must exist.
  pods_ok="$(k -n "$ns" get pods -l app=frontend -o json | jq --arg img "boutique/frontend:${version}" \
    '[.items[] | select(.status.phase=="Running" and .metadata.deletionTimestamp==null)]
     | {total: length, wrong: map(select(.spec.containers[0].image != $img)) | length}
     | "\(.total) \(.wrong)"' -r)"
  read -r pods_total pods_bad <<<"$pods_ok"
  (( pods_total > 0 && pods_bad == 0 )) \
    || { warn "frontend pods: ${pods_total} running, ${pods_bad} not on ${version}"; return 1; }
  # "|| true": with set -e a curl failure (e.g. Gateway unreachable) would
  # abort the caller silently instead of reaching the warn below.
  header="$(curl -sS --max-time 10 -I --resolve "${host}:80:${ip}" "http://${host}/" 2>/dev/null \
    | awk -F': ' 'tolower($1)=="x-app-version"{print $2}' | tr -d '\r' || true)"
  [[ "$header" == "$version" ]] || { warn "X-App-Version is '${header:-none}', expected ${version}"; return 1; }
  ok "$env frontend on ${version}: Deployment, all running pods, X-App-Version"
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
