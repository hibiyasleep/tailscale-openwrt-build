#!/usr/bin/env bash
# lib.sh — common setup sourced by build.sh and package.sh.
# Loads build.conf and resolves what both scripts need:
#   SCRIPT_DIR  — repo root (this file's directory)
#   VERSION     — Tailscale version, without the leading 'v'
#   TARGETS     — opkg arch names to act on (CLI args, else build.conf)
# TAILSCALE_VERSION is also exported (with the 'v') for the git clone / stamps.

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
