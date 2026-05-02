#!/usr/bin/env bash
# build.sh — top-level entry point for the Apple xcframework build.
#
# Status: FIRST DRAFT — orchestration shape is right, but the per-library
# meson/configure invocations need real iteration on a Mac. Treat this as
# a working skeleton, not a finished build.
#
# Usage:
#   apple/scripts/build.sh                                  # full matrix
#   apple/scripts/build.sh --slice ios-arm64                # one slice only
#   apple/scripts/build.sh --slice ios-arm64 --lib libplacebo
#   apple/scripts/build.sh --clean                          # nuke build/, keep deps/
#
# Outputs:
#   build/deps/<name>-<version>/   — dependency sources (cached across runs)
#   build/<slice>/<lib>/           — per-slice build trees
#   build/<slice>/prefix/          — installed headers + static libs per slice
#   build/xcframeworks/Lib*.xcframework

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLE_DIR="$REPO_ROOT/apple"
BUILD_DIR="$REPO_ROOT/build"
DEPS_DIR="$BUILD_DIR/deps"
XCF_DIR="$BUILD_DIR/xcframeworks"

ALL_SLICES=(
  "ios-arm64"
  "ios-arm64_x86_64-simulator"
  # maccatalyst-arm64_x86_64 is intentionally disabled in the default matrix.
  # ffmpeg's libavformat/tls_securetransport.c uses SecItemImport /
  # SecExternalFormat, which are macOS-only Security APIs that the Mac
  # Catalyst SDK doesn't expose. Without them the file fails to compile,
  # and disabling --enable-securetransport would leave Catalyst with no
  # TLS backend at all (no HTTPS streaming for Jellyfin). Re-enable once
  # we either ship a Network.framework-based TLS path or bring in
  # OpenSSL/GnuTLS for the Catalyst slice. Pass `--slice
  # maccatalyst-arm64_x86_64` explicitly to attempt it.
  "tvos-arm64"
  "tvos-arm64_x86_64-simulator"
)

ALL_LIBS=(
  "freetype"
  "fribidi"
  "harfbuzz"
  "libunibreak"
  "libass"
  "lcms2"
  "MoltenVK"
  "ffmpeg"
  "glslang"
  "libplacebo"
  "mpv"
)

# ── argv parsing ────────────────────────────────────────────────────────────

SLICES=()
LIBS=()
CLEAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slice)
      SLICES+=("$2"); shift 2 ;;
    --lib)
      LIBS+=("$2"); shift 2 ;;
    --clean)
      CLEAN=1; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0"; exit 0 ;;
    *)
      echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Default to all slices/libs if the user didn't restrict.
[[ ${#SLICES[@]} -eq 0 ]] && SLICES=("${ALL_SLICES[@]}")
[[ ${#LIBS[@]}   -eq 0 ]] && LIBS=("${ALL_LIBS[@]}")

# ── prerequisite check ─────────────────────────────────────────────────────

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing: $1 (brew install $1?)" >&2; exit 1; }
}
require meson
require ninja
require nasm
require pkg-config
require automake
require autoconf
require libtool
require cmake
require xcodebuild

# ── prepare ────────────────────────────────────────────────────────────────

if [[ "$CLEAN" -eq 1 ]]; then
  rm -rf "$BUILD_DIR" || true
fi

mkdir -p "$DEPS_DIR" "$XCF_DIR"

# ── fetch ──────────────────────────────────────────────────────────────────

echo "==> fetch-deps"
"$APPLE_DIR/scripts/fetch-deps.sh" "$DEPS_DIR"

# ── build per slice ────────────────────────────────────────────────────────

for slice in "${SLICES[@]}"; do
  echo "==> slice: $slice"
  for lib in "${LIBS[@]}"; do
    echo "    -> $lib"
    "$APPLE_DIR/scripts/build-slice.sh" "$slice" "$lib" "$DEPS_DIR" "$BUILD_DIR/$slice"
  done
done

# ── package as xcframeworks ────────────────────────────────────────────────

echo "==> package xcframeworks"
"$APPLE_DIR/scripts/package-xcframeworks.sh" "$BUILD_DIR" "$XCF_DIR" "${SLICES[@]}"

echo "Done. Artifacts in $XCF_DIR"
