#!/usr/bin/env bash
# package.sh [OPKG_ARCH ...]   e.g. ./package.sh mipsel_24kc
# Packages tailscale combined binaries into .ipk files and generates the opkg feed.
# With no arguments, packages all ARCHITECTURES defined in build.conf.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/build.conf"

# Optional opkg feed signing. Point USIGN_SEC at a usign secret-key file to emit
# a Packages.sig next to each feed index (opkg verifies this when check_signature
# is enabled). Leave unset for an unsigned local build.
USIGN_SEC="${USIGN_SEC:-}"

# Resolve version for package metadata
if [ "$TAILSCALE_VERSION" = "latest" ]; then
  TAILSCALE_VERSION="$(curl -fsSL https://api.github.com/repos/tailscale/tailscale/releases/latest | jq -r .tag_name)"
fi
VERSION="${TAILSCALE_VERSION#v}"

### Which architectures?
if [ $# -gt 0 ]; then
  TARGETS=("$@")
else
  TARGETS=("${ARCHITECTURES[@]}")
fi

### Helper: the opkg arch name is the label verbatim
# It ends up in the .ipk filename, the control "Architecture:" field, the feed
# path, and must match `opkg print-architecture` on the device.
parse_arch() {
  _ARCH_LABEL="$1"
}

### Helper: build one .ipk
build_ipk() {
  local arch_label="$1"
  local binary="$SCRIPT_DIR/tailscale.combined.${arch_label}"

  if [ ! -f "$binary" ]; then
    echo "SKIP: $binary not found (run build.sh first)" >&2
    return 1
  fi

  local pkg_name="tailscale"
  local ipk_file="$SCRIPT_DIR/${pkg_name}_${VERSION}_${arch_label}.ipk"
  local work="$SCRIPT_DIR/_ipk-work-${arch_label}"

  rm -rf "$work"
  mkdir -p "$work"/{control,data}

  ### data tree
  mkdir -p "$work/data/usr/sbin"
  install -m755 "$binary" "$work/data/usr/sbin/tailscaled"
  ln -sf tailscaled "$work/data/usr/sbin/tailscale"

  # init script (procd)
  mkdir -p "$work/data/etc/init.d"
  cat > "$work/data/etc/init.d/tailscale" <<'INITEOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

start_service() {
    local state_dir
    config_load tailscale
    config_get state_dir settings state_dir "/var/lib/tailscale"
    mkdir -p "$state_dir"

    procd_open_instance
    procd_set_param command /usr/sbin/tailscaled
    procd_append_param command --state "${state_dir}/tailscaled.state"
    procd_append_param command --socket "${state_dir}/tailscaled.sock"
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    /usr/sbin/tailscale down 2>/dev/null || true
}
INITEOF
  chmod 755 "$work/data/etc/init.d/tailscale"

  # UCI config
  mkdir -p "$work/data/etc/config"
  cat > "$work/data/etc/config/tailscale" <<'CONFEOF'
config settings 'settings'
    option state_dir '/var/lib/tailscale'
CONFEOF

  ### control metadata
  local installed_size
  installed_size="$(stat -f%z "$binary" 2>/dev/null || stat -c%s "$binary")"
  cat > "$work/control/control" <<EOF
Package: ${pkg_name}
Version: ${VERSION}
Architecture: ${arch_label}
Maintainer: auto-build
Description: Tailscale VPN combined binary (${arch_label}) built with aggressive ts_omit and UPX compression.
Installed-Size: ${installed_size}
Depends: libc, kmod-tun, iptables
Section: net
Priority: optional
EOF

  cat > "$work/control/postinst" <<'EOF'
#!/bin/sh
[ -x /etc/init.d/tailscale ] && /etc/init.d/tailscale enable
exit 0
EOF
  chmod 755 "$work/control/postinst"

  cat > "$work/control/prerm" <<'EOF'
#!/bin/sh
[ -x /etc/init.d/tailscale ] && /etc/init.d/tailscale disable
/etc/init.d/tailscale stop 2>/dev/null || true
exit 0
EOF
  chmod 755 "$work/control/prerm"

  # Assemble .ipk
  echo "2.0" > "$work/debian-binary"
  (cd "$work/control" && tar czf "$work/control.tar.gz" .)
  (cd "$work/data"    && tar czf "$work/data.tar.gz" .)

  rm -f "$ipk_file"
  (cd "$work" && ar rc "$ipk_file" debian-binary control.tar.gz data.tar.gz)
  echo "Created: $ipk_file ($(ls -lh "$ipk_file" | awk '{print $5}'))"

  # Copy into per-arch feed dir
  local feed_dir="$SCRIPT_DIR/feed/packages/${arch_label}"
  mkdir -p "$feed_dir"
  cp "$ipk_file" "$feed_dir/"

  rm -rf "$work"
}

### Build .ipk for each arch
for spec in "${TARGETS[@]}"; do
  parse_arch "$spec"
  echo ""
  echo "━━━ Packaging ${_ARCH_LABEL} ━━━"
  build_ipk "$_ARCH_LABEL"
done

# Generate opkg feed index (per-arch)
for spec in "${TARGETS[@]}"; do
  parse_arch "$spec"
  feed_dir="$SCRIPT_DIR/feed/packages/${_ARCH_LABEL}"
  [ -d "$feed_dir" ] || continue
  (
    cd "$feed_dir"
    {
      for ipk in *.ipk; do
        [ -f "$ipk" ] || continue
        ar p "$ipk" control.tar.gz | tar xzfO - ./control 2>/dev/null || \
        ar p "$ipk" control.tar.gz | tar xzfO - control
        echo "Filename: $ipk"
        echo "Size: $(stat -f%z "$ipk" 2>/dev/null || stat -c%s "$ipk")"
        echo "SHA256sum: $(sha256sum "$ipk" | awk '{print $1}')"
        echo ""
      done
    } > Packages
    gzip -kf Packages

    ### Sign the (uncompressed) index — opkg verifies Packages.sig after gunzip.
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
done

echo ""
echo "Done. Feed tree:"
find "$SCRIPT_DIR/feed" -type f 2>/dev/null | sort
