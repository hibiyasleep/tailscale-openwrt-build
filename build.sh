#!/usr/bin/env bash
# build.sh [OPKG_ARCH ...]   e.g. ./build.sh mipsel_24kc
# Builds tailscale combined binaries for each specified OpenWRT arch.
# With no arguments, builds all ARCHITECTURES defined in build.conf.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/build.conf"

### Resolve version
if [ "$TAILSCALE_VERSION" = "latest" ]; then
  TAILSCALE_VERSION="$(curl -fsSL https://api.github.com/repos/tailscale/tailscale/releases/latest | jq -r .tag_name)"
  echo "Resolved latest Tailscale version: $TAILSCALE_VERSION"
fi
export TAILSCALE_VERSION

# Which architectures to build?
if [ $# -gt 0 ]; then
  TARGETS=("$@")
else
  TARGETS=("${ARCHITECTURES[@]}")
fi

### Clone source (once)
SRC_DIR="$SCRIPT_DIR/_tailscale-src"
if [ ! -d "$SRC_DIR/.git" ]; then
  rm -rf "$SRC_DIR"
  git clone --depth 1 --branch "$TAILSCALE_VERSION" https://github.com/tailscale/tailscale.git "$SRC_DIR"
fi

# Assemble build tags (via featuretags tool)
FEATURES_CSV="$(IFS=,; echo "${FEATURES[*]}")"
TAGS="$(cd "$SRC_DIR" && go run ./cmd/featuretags --min --add "$FEATURES_CSV")"
echo "Build tags: $TAGS"

# Version stamps
VERSION_PKG="tailscale.com/version"
SHORT="${TAILSCALE_VERSION#v}"
LONG="${SHORT}-g$(cd "$SRC_DIR" && git rev-parse --short HEAD)"
LDFLAGS="-s -w -X ${VERSION_PKG}.longStamp=${LONG} -X ${VERSION_PKG}.shortStamp=${SHORT}"

### Helper: derive the Go toolchain env from an OpenWRT/opkg arch name.
# opkg arch names are MORE specific than Go's (many opkg names map onto one Go config),
# so GOARCH/GOMIPS/GOARM are derivable from the opkg name — the reverse
# is not. _ARCH_LABEL is just the opkg name itself (used for the output filename).
parse_arch() {
  local arch="$1"
  _ARCH_LABEL="$arch"
  _GOARCH=""
  _GOMIPS=""
  _GOARM=""
  _GOARM64=""
  case "$arch" in
    mipsel_*)   _GOARCH=mipsle  ; _GOMIPS=softfloat ;;  # ramips, etc.
    mips64el_*) _GOARCH=mips64le ;;
    mips64_*)   _GOARCH=mips64 ;;
    mips_*)     _GOARCH=mips    ; _GOMIPS=softfloat ;;  # ath79, lantiq, etc.
    aarch64_*)  _GOARCH=arm64 ;;
    x86_64)     _GOARCH=amd64 ;;
    i386_*)     _GOARCH=386 ;;
    riscv64_*)  _GOARCH=riscv64 ;;
    arm_*)
      _GOARCH=arm
      case "$arch" in
        # Older cores predate ARMv7. Everything else (cortex-a7/a9/a15/…) is v7.
        arm_arm926ej-s|arm_fa526|arm_xscale|arm_arm920t) _GOARM=5 ;;
        arm_arm1176jzf-s|arm_mpcore)                     _GOARM=6 ;;
        *)                                               _GOARM=7 ;;
      esac
      ;;
    *)
      echo "ERROR: unknown opkg arch '$arch' — add a case to parse_arch() in build.sh" >&2
      exit 1
      ;;
  esac
}

### Build loop
for spec in "${TARGETS[@]}"; do
  parse_arch "$spec"
  OUTPUT="$SCRIPT_DIR/tailscale.combined.${_ARCH_LABEL}"
  echo ""
  echo "━━━ Building for ${_ARCH_LABEL} (GOARCH=${_GOARCH}) ━━━"

  (
    cd "$SRC_DIR"
    CGO_ENABLED=0 GOOS=linux GOARCH="$_GOARCH" GOMIPS="$_GOMIPS" GOARM="$_GOARM" GOARM64="$_GOARM64" \
      go build -trimpath \
        -tags "$TAGS" \
        -ldflags "$LDFLAGS" \
        -o "$OUTPUT" \
        ./cmd/tailscaled
  )
  echo "Built: $OUTPUT ($(ls -lh "$OUTPUT" | awk '{print $5}'))"

  # UPX
  if [ "$UPX_ENABLED" = "true" ]; then
    if command -v upx >/dev/null 2>&1; then
      echo "Compressing with UPX…"
      upx --best --lzma "$OUTPUT" || echo "WARNING: UPX failed for ${_ARCH_LABEL}, keeping uncompressed"
      echo "Compressed: $(ls -lh "$OUTPUT" | awk '{print $5}')"
    else
      echo "WARNING: UPX not found in PATH, skipping compression"
    fi
  fi
done

### Cleanup source
rm -rf "$SRC_DIR"

echo ""
echo "Done. Binaries:"
ls -lh "$SCRIPT_DIR"/tailscale.combined.* 2>/dev/null || true
