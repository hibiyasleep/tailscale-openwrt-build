#!/usr/bin/env bash
# lib.sh — common setup sourced by build.sh, package.sh and package-apk.sh.
# Loads build.conf and resolves what the sourcing scripts need:
#   SCRIPT_DIR  — repo root (this file's directory)
#   VERSION     — Tailscale version, without the leading 'v'
#   TARGETS     — opkg arch names to act on (CLI args, else build.conf)
# TAILSCALE_VERSION is also exported (with the 'v') for the git clone / stamps.
# It also defines stage_payload(), the on-device file layout shared by both
# packagers.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/build.conf"

# Resolve "latest" to a concrete release tag via the GitHub API.
if [ "$TAILSCALE_VERSION" = "latest" ]; then
  TAILSCALE_VERSION="$(curl -fsSL https://api.github.com/repos/tailscale/tailscale/releases/latest | jq -r .tag_name)"
  echo "Resolved latest Tailscale version: $TAILSCALE_VERSION"
fi
export TAILSCALE_VERSION
# shellcheck disable=SC2034  # VERSION/TARGETS are consumed by the sourcing script
VERSION="${TAILSCALE_VERSION#v}"

# Positional args of the sourcing script override build.conf's ARCHITECTURES.
# shellcheck disable=SC2034
if [ "$#" -gt 0 ]; then
  TARGETS=("$@")
else
  TARGETS=("${ARCHITECTURES[@]}")
fi

# stage_payload <binary> <root> — lay out the on-device file tree shared by the
# .ipk and .apk packagers: tailscaled, the `tailscale` CLI as a relative
# symlink, the procd init script, and the default UCI config. Shipping the
# symlink in the payload (rather than creating it from a postinst) lets the
# package manager track and remove it, and keeps the CLI present even for
# offline image-builder installs. Callers must pass a fresh, empty <root>.
stage_payload() {
  local binary="$1" root="$2"
  mkdir -p "$root/usr/sbin" "$root/etc/init.d" "$root/etc/config"
  install -m755 "$binary" "$root/usr/sbin/tailscaled"
  ln -s tailscaled "$root/usr/sbin/tailscale"
  install -m755 "$SCRIPT_DIR/files/tailscale.init" "$root/etc/init.d/tailscale"
  install -m644 "$SCRIPT_DIR/files/tailscale.conf" "$root/etc/config/tailscale"
}
