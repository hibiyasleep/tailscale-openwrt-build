#!/usr/bin/env bash
# package-apk.sh [OPKG_ARCH ...]   e.g. ./package-apk.sh mipsel_24kc
# Packages each prebuilt tailscale binary into an OpenWRT-25 .apk (apk-tools 3,
# APKv3/ADB format) and (re)generates the per-arch apk feed index (packages.adb).
# With no arguments, packages every arch in build.conf.
#
# This is the apk counterpart to package.sh (.ipk / opkg). Both write into the
# same feed/packages/<arch>/ tree, where opkg's Packages and apk's packages.adb
# coexist. apk arch names are identical to opkg's, so build.conf is shared.
#
# Requires apk-tools 3 (the `apk` CLI with the `mkpkg`/`mkndx` subcommands) in
# PATH, and — to record root:root file ownership — fakeroot (Linux only).

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Optional apk feed signing: point APK_SIGN_KEY at an EC (prime256v1) private
# key in PEM form to sign each arch's packages.adb (apk verifies it against the
# matching public key in /etc/apk/keys/ on the device). Leave unset for an
# unsigned local build. Generate a keypair with:
#   openssl ecparam -name prime256v1 -genkey -noout -out tailscale-apk.sec
#   openssl ec -in tailscale-apk.sec -pubout -out tailscale-apk.pem
APK_SIGN_KEY="${APK_SIGN_KEY:-}"

# apk versions carry a "-r<N>" release suffix; bump APK_RELEASE to re-release the
# same upstream version. (1.98.5-r2 > 1.98.5-r1 in apk's version ordering.)
APK_RELEASE="${APK_RELEASE:-1}"
APK_VERSION="${VERSION}-r${APK_RELEASE}"

# Pin the download filename apk records in the index to the file we actually
# write (default would otherwise drift between apk-tools versions).
PKGNAME_SPEC='${name}-${version}.apk'

command -v apk >/dev/null 2>&1 || {
  echo "ERROR: 'apk' (apk-tools 3) not found in PATH." >&2
  echo "       Install apk-tools 3 (it provides 'apk mkpkg' / 'apk mkndx')." >&2
  exit 1
}

# apk reads file ownership from the staged tree, so without privileges the
# payload would land under the build user's uid/gid on the device. fakeroot
# fakes root:root ownership; it works on Linux (and is what OpenWRT's build
# system uses) but is a no-op on macOS under SIP, so restrict it to Linux.
FAKEROOT=""
if [ "$(uname -s)" = "Linux" ] && command -v fakeroot >/dev/null 2>&1; then
  FAKEROOT="$(command -v fakeroot)"
else
  echo "NOTE: fakeroot unavailable or non-Linux host — .apk files will be owned" >&2
  echo "      by the build user (fine for local testing; CI packages under fakeroot)." >&2
fi

# Run 'apk mkpkg ...' (passed as argv) with the staged tree chowned to root:root
# under fakeroot when available.
mkpkg_rooted() {
  local root="$1"; shift
  if [ -n "$FAKEROOT" ]; then
    "$FAKEROOT" -- bash -c 'chown -R 0:0 "$1"; shift; exec "$@"' _ "$root" "$@"
  else
    "$@"
  fi
}

### Package one arch's binary into an .apk and stage it into the feed tree.
build_apk() {
  local arch="$1"
  local binary="$SCRIPT_DIR/tailscale.combined.${arch}"
  if [ ! -f "$binary" ]; then
    echo "SKIP: $binary not found (run build.sh first)" >&2
    return 1
  fi

  local feed_dir="$SCRIPT_DIR/feed/packages/${arch}"
  local apk="$feed_dir/tailscale-${APK_VERSION}.apk"
  local root="$SCRIPT_DIR/_apk-work-${arch}"
  rm -rf "$root"
  mkdir -p "$root" "$feed_dir"

  ### data tree (shared layout; see stage_payload in lib.sh)
  stage_payload "$binary" "$root"

  ### build the package
  # The static Go binary needs no libc dependency. ca-bundle supplies the TLS
  # roots for the control server; kmod-tun the TUN device. (Per the .ipk notes,
  # do NOT depend on iptables — it breaks installs on nftables/fw4-only systems.)
  rm -f "$apk"
  mkpkg_rooted "$root" apk mkpkg \
    --info "name:tailscale" \
    --info "version:${APK_VERSION}" \
    --info "arch:${arch}" \
    --info "description:Tailscale VPN combined binary (${arch}) built with aggressive omitting and compression." \
    --info "license:BSD-3-Clause" \
    --info "origin:tailscale" \
    --info "url:https://tailscale.com" \
    --info "maintainer:auto-build" \
    --info "depends:ca-bundle kmod-tun" \
    --info "provides:tailscaled" \
    --script "post-install:$SCRIPT_DIR/files/tailscale.apk-post-install" \
    --script "pre-deinstall:$SCRIPT_DIR/files/tailscale.apk-pre-deinstall" \
    --files "$root" \
    --output "$apk"

  rm -rf "$root"
  echo "Created: $apk ($(ls -lh "$apk" | awk '{print $5}'))"
}

### (Re)generate one arch's apk index (packages.adb), signing it when
### APK_SIGN_KEY is set. Packages themselves are left unsigned (OpenWRT's model
### since late 2025): trust flows from the signed index, which records each
### package's hash. --allow-untrusted lets mkndx accept the unsigned packages.
index_apk() {
  local feed_dir="$SCRIPT_DIR/feed/packages/$1"
  [ -d "$feed_dir" ] || return 0
  shopt -s nullglob
  local apks=("$feed_dir"/*.apk)
  shopt -u nullglob
  [ "${#apks[@]}" -gt 0 ] || return 0

  local -a sign=()
  if [ -n "$APK_SIGN_KEY" ]; then
    sign=(--sign-key "$APK_SIGN_KEY")
  else
    echo "WARN: APK_SIGN_KEY unset; feed index left UNSIGNED" >&2
  fi

  ( cd "$feed_dir" && apk mkndx --allow-untrusted "${sign[@]}" \
      --pkgname-spec "$PKGNAME_SPEC" --output packages.adb ./*.apk )

  [ -n "$APK_SIGN_KEY" ] && echo "Signed: $feed_dir/packages.adb"
  echo "Feed index: $feed_dir/packages.adb"
}

for arch in "${TARGETS[@]}"; do
  echo ""
  echo "--- Packaging ${arch} (apk) ---"
  build_apk "$arch" && index_apk "$arch"
done

echo ""
echo "Done. Feed tree:"
find "$SCRIPT_DIR/feed" -type f 2>/dev/null | sort
