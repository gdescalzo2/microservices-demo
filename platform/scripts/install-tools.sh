#!/usr/bin/env bash
# Installs the CLI tools used by the challenge into ~/.local/bin (no sudo).
# Docker Engine is a prerequisite and is NOT installed here (needs root and a
# group change): see README "Prerequisiti".
#
# Usage: platform/scripts/install-tools.sh
# Versions are pinned below (verified together on 2026-11-18) and can be
# overridden per tool, e.g. HELM_VERSION=v4.3.3. A tool already on PATH is
# not reinstalled; the report at the end flags any version that differs from
# the pin. Unpinned "latest" downloads made the platform drift silently.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

BIN="${HOME}/.local/bin"
mkdir -p "$BIN"
case ":$PATH:" in *":$BIN:"*) ;; *) warn "add $BIN to PATH: export PATH=\"$BIN:\$PATH\"";; esac
export PATH="$BIN:$PATH"

ARCH="$(uname -m)"; case "$ARCH" in x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; *) die "unsupported arch $ARCH";; esac
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

KIND_VERSION="${KIND_VERSION:-v0.33.0}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.37.2}"
HELM_VERSION="${HELM_VERSION:-v4.3.2}"
KUSTOMIZE_VERSION="${KUSTOMIZE_VERSION:-v5.8.3}"
KUBECONFORM_VERSION="${KUBECONFORM_VERSION:-v0.8.0}"
ARGOCD_CLI_VERSION="${ARGOCD_CLI_VERSION:-v3.6.1}"
K9S_VERSION="${K9S_VERSION:-v0.51.0}"

install_bin() { install -m 0755 "$1" "$BIN/$2"; ok "installed $2"; }

command -v docker >/dev/null || die "Docker Engine not found: install it first (README, Prerequisiti)"
docker info >/dev/null 2>&1 || die "docker is installed but not usable by $USER (sudo usermod -aG docker \$USER, then log out/in)"

step "kind"
if ! command -v kind >/dev/null; then
  curl -fsSLo "$TMP/kind" "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-${ARCH}"
  install_bin "$TMP/kind" kind
fi

step "kubectl"
if ! command -v kubectl >/dev/null; then
  curl -fsSLo "$TMP/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
  install_bin "$TMP/kubectl" kubectl
fi

step "helm"
if ! command -v helm >/dev/null; then
  curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" | tar xz -C "$TMP"
  install_bin "$TMP/linux-${ARCH}/helm" helm
fi

step "kustomize"
if ! command -v kustomize >/dev/null; then
  curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_${ARCH}.tar.gz" | tar xz -C "$TMP"
  install_bin "$TMP/kustomize" kustomize
fi

step "kubeconform"
if ! command -v kubeconform >/dev/null; then
  curl -fsSL "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-${ARCH}.tar.gz" | tar xz -C "$TMP"
  install_bin "$TMP/kubeconform" kubeconform
fi

step "argocd CLI"
if ! command -v argocd >/dev/null; then
  curl -fsSLo "$TMP/argocd" "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_CLI_VERSION}/argocd-linux-${ARCH}"
  install_bin "$TMP/argocd" argocd
fi

step "k9s (terminal UI, handy during the demo)"
if ! command -v k9s >/dev/null; then
  curl -fsSL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${ARCH}.tar.gz" | tar xz -C "$TMP"
  install_bin "$TMP/k9s" k9s
fi

step "Installed versions (pinned in parentheses)"
docker version --format 'docker      {{.Server.Version}}  (prerequisite, not pinned here)'
mismatch=0
report() { # report <tool> <installed> <pinned>
  if [[ "$2" == "$3" ]]; then printf '%-11s %s\n' "$1" "$2"
  else printf '%-11s %s  (pinned %s)\n' "$1" "${2:-?}" "$3"; warn "$1 is ${2:-unknown}, pinned ${3}"; mismatch=1; fi
}
report kind        "$(kind version | awk '{print $2}')" "$KIND_VERSION"
report kubectl     "$(kubectl version --client -o json | sed -n 's/.*"gitVersion": "\(.*\)".*/\1/p' | head -1)" "$KUBECTL_VERSION"
report helm        "$(helm version --template '{{.Version}}')" "$HELM_VERSION"
report kustomize   "$(kustomize version)" "$KUSTOMIZE_VERSION"
report kubeconform "$(kubeconform -v)" "$KUBECONFORM_VERSION"
report argocd      "$(argocd version --client --short 2>/dev/null | head -1 | sed -E 's/^argocd: //; s/\+.*//')" "$ARGOCD_CLI_VERSION"
report k9s         "$(k9s version --short 2>/dev/null | awk '/Version/{print $2}')" "$K9S_VERSION"
if (( mismatch == 0 )); then
  ok "all tools match the pinned versions"
else
  warn "some tools differ from the pins: remove them from $BIN and rerun to install the pinned version"
fi
