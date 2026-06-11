#!/usr/bin/env bash
# package.sh [OPKG_ARCH ...]   e.g. ./package.sh mipsel_24kc
# Packages each prebuilt tailscale binary into an .ipk and (re)generates the
# per-arch opkg feed index. With no arguments, packages every arch in build.conf.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Optional opkg feed signing: point USIGN_SEC at a usign secret-key file to emit
# a Packages.sig beside each feed index (opkg checks it when check_signature is
# enabled). Leave unset for an unsigned local build.
USIGN_SEC="${USIGN_SEC:-}"

# Every member of an .ipk's tarballs must be owned by root:root (numeric), or
# files land under the build user's uid/gid on the device. GNU/BSD tar differ.
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  TAR_OPTS="--numeric-owner --owner=0 --group=0"
else
  TAR_OPTS="--numeric-owner --uid 0 --gid 0"
fi

# Portable helpers (Linux/CI vs macOS).
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}
filesize() {
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1"
}

### Package one arch's binary into an .ipk and stage it into the feed tree.
build_ipk() {
  local arch="$1"
  local binary="$SCRIPT_DIR/tailscale.combined.${arch}"
  if [ ! -f "$binary" ]; then
    echo "SKIP: $binary not found (run build.sh first)" >&2
    return 1
  fi

  local ipk="$SCRIPT_DIR/tailscale_${VERSION}_${arch}.ipk"
  local work="$SCRIPT_DIR/_ipk-work-${arch}"
  rm -rf "$work"
  mkdir -p "$work"/{control,data}

  local control="$work/control"
  local data="$work/data"

  ### data tree (shared layout; see stage_payload in lib.sh)
  stage_payload "$binary" "$data"

  ### control tree
  cat > "$work/control/control" <<EOF
Package: tailscale
Version: ${VERSION}
Architecture: ${arch}
Maintainer: auto-build
Description: Tailscale VPN combined binary (${arch}) built with aggressive omitting and compression.
Installed-Size: $(filesize "$binary")
Depends: libc, ca-bundle, kmod-tun
Provides: tailscaled
Section: net
Priority: optional
EOF

  install -m644 "$SCRIPT_DIR/files/tailscale.conffiles" "$control/conffiles"
  install -m755 "$SCRIPT_DIR/files/tailscale.postinst" "$control/postinst"
  install -m755 "$SCRIPT_DIR/files/tailscale.prerm"    "$control/prerm"

  ### assemble
  # an OpenWRT .ipk is a gzipped tar (not an `ar` archive), every member owned by root:root.
  echo "2.0" > "$work/debian-binary"
  (cd "$control" && tar $TAR_OPTS -czf "$work/control.tar.gz" ./*)
  (cd "$data"    && tar $TAR_OPTS -czf "$work/data.tar.gz" ./*)
  rm -f "$ipk"
  (cd "$work" && tar $TAR_OPTS -czf "$ipk" ./debian-binary ./control.tar.gz ./data.tar.gz)
  rm -rf "$work"

  mkdir -p "$SCRIPT_DIR/feed/packages/${arch}"
  cp "$ipk" "$SCRIPT_DIR/feed/packages/${arch}/"
  echo "Created: $ipk ($(ls -lh "$ipk" | awk '{print $5}'))"
}

### (Re)generate one arch's opkg Packages index, signing it when USIGN_SEC is set.
index_feed() {
  local feed_dir="$SCRIPT_DIR/feed/packages/$1"
  [ -d "$feed_dir" ] || return 0
  (
    cd "$feed_dir"
    {
      for ipk in *.ipk; do
        [ -f "$ipk" ] || continue
        # .ipk is a gzipped tar: pull control.tar.gz out, then ./control from it.
        tar -xzOf "$ipk" ./control.tar.gz 2>/dev/null | tar -xzO ./control 2>/dev/null || \
        tar -xzOf "$ipk" control.tar.gz 2>/dev/null | tar -xzO control
        echo "Filename: $ipk"
        echo "Size: $(filesize "$ipk")"
        echo "SHA256sum: $(sha256 "$ipk")"
        echo ""
      done
    } > Packages
    gzip -kf Packages

    if [ -n "$USIGN_SEC" ]; then
      if command -v usign >/dev/null 2>&1; then
        usign -S -m Packages -s "$USIGN_SEC" -x Packages.sig
        echo "Signed: Packages.sig"
      else
        echo "WARN: USIGN_SEC set but 'usign' not in PATH; feed left UNSIGNED" >&2
      fi
    fi
  )
  echo "Feed index: $feed_dir/Packages"
}

for arch in "${TARGETS[@]}"; do
  echo ""
  echo "--- Packaging ${arch} ---"
  build_ipk "$arch" && index_feed "$arch"
done

echo ""
echo "Done. Feed tree:"
find "$SCRIPT_DIR/feed" -type f 2>/dev/null | sort
