#!/usr/bin/env bash
# Installs the CLI tools used by the challenge into ~/.local/bin (no sudo).
# Docker Engine is a prerequisite and is NOT installed here (needs root and a
# group change): see README "Prerequisiti".
#
# Usage: platform/scripts/install-tools.sh
# Each tool is skipped if already on PATH. Versions: latest stable at install
# time; the installed versions are printed at the end (record them in
# docs/challenge/versions.md after the first successful run).
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

BIN="${HOME}/.local/bin"
mkdir -p "$BIN"
case ":$PATH:" in *":$BIN:"*) ;; *) warn "add $BIN to PATH: export PATH=\"$BIN:\$PATH\"";; esac
export PATH="$BIN:$PATH"

ARCH="$(uname -m)"; case "$ARCH" in x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; *) die "unsupported arch $ARCH";; esac
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Latest release tag of a GitHub repo, via the redirect of /releases/latest
# (avoids the rate-limited GitHub API).
gh_latest() {
  basename "$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest")"
}

install_bin() { install -m 0755 "$1" "$BIN/$2"; ok "installed $2"; }

command -v docker >/dev/null || die "Docker Engine not found: install it first (README, Prerequisiti)"
docker info >/dev/null 2>&1 || die "docker is installed but not usable by $USER (sudo usermod -aG docker \$USER, then log out/in)"

step "kind"
if ! command -v kind >/dev/null; then
  curl -fsSLo "$TMP/kind" "https://github.com/kubernetes-sigs/kind/releases/latest/download/kind-linux-${ARCH}"
  install_bin "$TMP/kind" kind
fi

step "kubectl"
if ! command -v kubectl >/dev/null; then
  v="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSLo "$TMP/kubectl" "https://dl.k8s.io/release/${v}/bin/linux/${ARCH}/kubectl"
  install_bin "$TMP/kubectl" kubectl
fi

step "helm"
if ! command -v helm >/dev/null; then
  v="$(gh_latest helm/helm)"
  curl -fsSL "https://get.helm.sh/helm-${v}-linux-${ARCH}.tar.gz" | tar xz -C "$TMP"
  install_bin "$TMP/linux-${ARCH}/helm" helm
fi

step "kustomize"
if ! command -v kustomize >/dev/null; then
  v="$(gh_latest kubernetes-sigs/kustomize)"          # e.g. kustomize/v5.7.1
  ver="${v#kustomize/}"
  curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${ver}/kustomize_${ver}_linux_${ARCH}.tar.gz" | tar xz -C "$TMP"
  install_bin "$TMP/kustomize" kustomize
fi

step "kubeconform"
if ! command -v kubeconform >/dev/null; then
  curl -fsSL "https://github.com/yannh/kubeconform/releases/latest/download/kubeconform-linux-${ARCH}.tar.gz" | tar xz -C "$TMP"
  install_bin "$TMP/kubeconform" kubeconform
fi

step "argocd CLI"
if ! command -v argocd >/dev/null; then
  curl -fsSLo "$TMP/argocd" "https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-${ARCH}"
  install_bin "$TMP/argocd" argocd
fi

step "k9s (terminal UI, handy during the demo)"
if ! command -v k9s >/dev/null; then
  curl -fsSL "https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_${ARCH}.tar.gz" | tar xz -C "$TMP"
  install_bin "$TMP/k9s" k9s
fi

step "Installed versions"
docker version --format 'docker      {{.Server.Version}}'
echo "kind        $(kind version | awk '{print $2}')"
echo "kubectl     $(kubectl version --client -o json | sed -n 's/.*"gitVersion": "\(.*\)".*/\1/p' | head -1)"
echo "helm        $(helm version --short)"
echo "kustomize   $(kustomize version)"
echo "kubeconform $(kubeconform -v)"
echo "argocd      $(argocd version --client --short 2>/dev/null | head -1)"
echo "k9s         $(k9s version --short 2>/dev/null | awk '/Version/{print $2}')"
