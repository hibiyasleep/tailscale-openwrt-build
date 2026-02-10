#!/usr/bin/env bash
# build.sh [GOARCH:VARIANT ...]
# Builds tailscale combined binaries for each specified architecture.
# With no arguments, builds all ARCHITECTURES defined in build.conf.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/build.conf"

# ── Resolve version ─────────────────────────────────────────────
if [ "$TAILSCALE_VERSION" = "latest" ]; then
  TAILSCALE_VERSION="$(curl -fsSL https://api.github.com/repos/tailscale/tailscale/releases/latest | jq -r .tag_name)"
  echo "Resolved latest Tailscale version: $TAILSCALE_VERSION"
fi
export TAILSCALE_VERSION

# ── Which architectures to build? ──────────────────────────────
if [ $# -gt 0 ]; then
  TARGETS=("$@")
else
  TARGETS=("${ARCHITECTURES[@]}")
fi

# ── Clone source (once) ────────────────────────────────────────
SRC_DIR="$SCRIPT_DIR/_tailscale-src"
if [ ! -d "$SRC_DIR/.git" ]; then
  rm -rf "$SRC_DIR"
  git clone --depth 1 --branch "$TAILSCALE_VERSION" https://github.com/tailscale/tailscale.git "$SRC_DIR"
fi

# ── Assemble build tags (via featuretags tool) ────────────────
FEATURES_CSV="$(IFS=,; echo "${FEATURES[*]}")"
TAGS="$(cd "$SRC_DIR" && go run ./cmd/featuretags --min --add "$FEATURES_CSV")"
echo "Build tags: $TAGS"

# ── Version stamps ──────────────────────────────────────────────
VERSION_PKG="tailscale.com/version"
SHORT="${TAILSCALE_VERSION#v}"
LONG="${SHORT}-g$(cd "$SRC_DIR" && git rev-parse --short HEAD)"
LDFLAGS="-s -w -X ${VERSION_PKG}.longStamp=${LONG} -X ${VERSION_PKG}.shortStamp=${SHORT}"

# ── Helper: parse GOARCH:VARIANT ────────────────────────────────
parse_arch() {
  local spec="$1"
  _GOARCH="${spec%%:*}"
  _VARIANT="${spec#*:}"
  [ "$_VARIANT" = "$_GOARCH" ] && _VARIANT=""   # no colon in spec

  # Map variant to the correct Go env var
  _GOMIPS="" ; _GOARM="" ; _GOARM64=""
  case "$_GOARCH" in
    mips|mipsle)  _GOMIPS="${_VARIANT:-softfloat}" ;;
    arm)          _GOARM="${_VARIANT:-7}" ;;
    arm64)        _GOARM64="${_VARIANT}" ;;
    *)            ;;  # amd64, riscv64, etc. — no sub-variant
  esac

  # Derive opkg-style arch label (e.g. mipsle_softfloat, arm_7, arm64)
  if [ -n "$_VARIANT" ]; then
    _ARCH_LABEL="${_GOARCH}_${_VARIANT}"
  else
    _ARCH_LABEL="${_GOARCH}"
  fi
}

# ── Build loop ──────────────────────────────────────────────────
for spec in "${TARGETS[@]}"; do
  parse_arch "$spec"
  OUTPUT="$SCRIPT_DIR/tailscale.combined.${_ARCH_LABEL}"
  echo ""
  echo "━━━ Building for ${_ARCH_LABEL} (GOARCH=${_GOARCH}) ━━━"

  (
    cd "$SRC_DIR"
    CGO_ENABLED=0 GOOS=linux \
      GOARCH="$_GOARCH" GOMIPS="$_GOMIPS" GOARM="$_GOARM" GOARM64="$_GOARM64" \
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

# ── Cleanup source ──────────────────────────────────────────────
rm -rf "$SRC_DIR"

echo ""
echo "Done. Binaries:"
ls -lh "$SCRIPT_DIR"/tailscale.combined.* 2>/dev/null || true
