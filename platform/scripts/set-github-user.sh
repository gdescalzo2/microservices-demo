#!/usr/bin/env bash
# Replaces the YOUR_GITHUB_USER placeholder in the platform files with the
# owner of your fork (Argo CD repo URLs, runbook links in alerts, Krateo).
# Run once after forking, then commit.
#
# Usage: platform/scripts/set-github-user.sh <github-user-or-org>
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
need git grep sed

USER_NAME="${1:?usage: $0 <github-user-or-org>}"
[[ "$USER_NAME" =~ ^[A-Za-z0-9-]+$ ]] || die "invalid GitHub name: $USER_NAME"

# platform/scripts is excluded: the scripts use the placeholder as a pattern.
mapfile -t files < <(grep -rl --exclude-dir=scripts "YOUR_GITHUB_USER" "$REPO_ROOT/platform" "$REPO_ROOT/docs/challenge" || true)
[[ ${#files[@]} -gt 0 ]] || { ok "no placeholders left"; exit 0; }
for f in "${files[@]}"; do
  sed -i "s/YOUR_GITHUB_USER/${USER_NAME}/g" "$f"
  ok "${f#"$REPO_ROOT"/}"
done
echo "    review with: git diff --stat   then commit and push"
