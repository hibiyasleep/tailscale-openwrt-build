#!/usr/bin/env bash
# build.sh [OPKG_ARCH ...]   e.g. ./build.sh mipsel_24kc
# Cross-compiles the tailscaled combined binary for each target arch.
# With no arguments, builds every arch in build.conf.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

### Clone the Tailscale source once.
SRC_DIR="$SCRIPT_DIR/_tailscale-src"
if [ ! -d "$SRC_DIR/.git" ]; then
  rm -rf "$SRC_DIR"
  git clone --depth 1 --branch "$TAILSCALE_VERSION" https://github.com/tailscale/tailscale.git "$SRC_DIR"
fi

### Build tags (keep only build.conf's FEATURES + their deps) and version stamps.
FEATURES_CSV="$(IFS=,; echo "${FEATURES[*]}")"
TAGS="$(cd "$SRC_DIR" && go run ./cmd/featuretags --min --add "$FEATURES_CSV")"
echo "Build tags: $TAGS"

LONG="${VERSION}-g$(cd "$SRC_DIR" && git rev-parse --short HEAD)"
LDFLAGS="-s -w -X tailscale.com/version.longStamp=${LONG} -X tailscale.com/version.shortStamp=${VERSION}"

### Derive the Go toolchain env from an opkg arch name.
# opkg names are MORE specific than Go's (many opkg names map onto one Go
# config), so GOARCH/GOMIPS/GOARM are derivable from the opkg name; the reverse
# is not. Sets the _GO* globals; the ones a target doesn't use stay empty and
# Go takes its default.
parse_arch() {
  _GOARCH="" _GOMIPS="" _GOARM=""
  case "$1" in
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
      case "$1" in
        # Older cores predate ARMv7; everything else (cortex-a7/a9/a15/…) is v7.
        arm_arm926ej-s|arm_fa526|arm_xscale|arm_arm920t) _GOARM=5 ;;
        arm_arm1176jzf-s|arm_mpcore)                     _GOARM=6 ;;
        *)                                               _GOARM=7 ;;
      esac
      ;;
    *)
      echo "ERROR: unknown opkg arch '$1'; add a case to parse_arch() in build.sh" >&2
      exit 1
      ;;
  esac
}

### Build (and optionally UPX-compress) one binary per target.
for arch in "${TARGETS[@]}"; do
  parse_arch "$arch"
  output="$SCRIPT_DIR/tailscale.combined.${arch}"
  echo ""
  echo "*** Building for ${arch} (GOARCH=${_GOARCH}) ***"

  (
    cd "$SRC_DIR"
    CGO_ENABLED=0 GOOS=linux GOARCH="$_GOARCH" GOMIPS="$_GOMIPS" GOARM="$_GOARM" \
      go build -trimpath -tags "$TAGS" -ldflags "$LDFLAGS" \
        -o "$output" ./cmd/tailscaled
  )
  echo "Built: $output ($(ls -lh "$output" | awk '{print $5}'))"

  if [ "$UPX_ENABLED" = "true" ]; then
    if command -v upx >/dev/null 2>&1; then
      echo "Compressing with UPX…"
      upx --best --lzma "$output" || echo "WARNING: UPX failed for ${arch}, keeping uncompressed"
      echo "Compressed: $(ls -lh "$output" | awk '{print $5}')"
    else
      echo "WARNING: UPX not found in PATH, skipping compression"
    fi
  fi
done

rm -rf "$SRC_DIR"
echo ""
echo "Done. Binaries:"
ls -lh "$SCRIPT_DIR"/tailscale.combined.* 2>/dev/null || true
