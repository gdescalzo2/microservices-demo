#!/usr/bin/env bash
# Removes everything bootstrap.sh created on this machine.
# Usage: platform/scripts/teardown.sh
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need kind docker

read -r -p "Delete kind cluster '$CLUSTER_NAME' and the cloud-provider-kind container? [y/N] " ans || ans=n
[[ "$ans" =~ ^[Yy]$ ]] || exit 0

kind delete cluster --name "$CLUSTER_NAME" && ok "cluster deleted"
docker rm -f cloud-provider-kind >/dev/null 2>&1 && ok "cloud-provider-kind removed" || true
# Proxies started by cloud-provider-kind for LoadBalancers/Gateways live on the
# "kind" docker network: list leftovers instead of guessing their names.
left="$(docker ps -a --filter network=kind --format '{{.Names}}' || true)"
[[ -z "$left" ]] || { warn "containers still on the 'kind' network (remove with docker rm -f):"; printf "    %s\n" "${left//$'\n'/ }"; }
if grep -q "# boutique-challenge$" /etc/hosts; then
  echo "  /etc/hosts still has the boutique entries: sudo sed -i '/# boutique-challenge\$/d' /etc/hosts"
fi
