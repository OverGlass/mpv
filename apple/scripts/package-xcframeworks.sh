#!/usr/bin/env bash
# package-xcframeworks.sh — fold per-slice prefix trees into XCFrameworks.
#
# For each library, walks every slice's prefix/lib/lib<name>.a, lipos the
# multi-arch slices into universal binaries, builds a .framework wrapper
# per slice, then runs xcodebuild -create-xcframework to produce one
# .xcframework per library. Output: <xcf_dir>/Lib<Name>.xcframework.
#
# Usage: package-xcframeworks.sh <build_dir> <xcf_dir> <slice...>

set -euo pipefail

BUILD_DIR="${1:?build_dir}"
XCF_DIR="${2:?xcf_dir}"
shift 2
SLICES=("$@")

LIBS=(
  "mpv"
  "avcodec" "avformat" "avfilter" "avutil" "swresample" "swscale" "postproc"
  "placebo"
  "MoltenVK"
  "ass" "freetype" "fribidi" "harfbuzz" "unibreak"
  "lcms2"
)

mkdir -p "$XCF_DIR"

# slice → xcframework slice id (the substring xcodebuild expects per platform).
slice_id() {
  case "$1" in
    ios-arm64)                       echo "ios-arm64" ;;
    ios-arm64_x86_64-simulator)      echo "ios-arm64_x86_64-simulator" ;;
    maccatalyst-arm64_x86_64)        echo "ios-arm64_x86_64-maccatalyst" ;;
    tvos-arm64)                      echo "tvos-arm64" ;;
    tvos-arm64_x86_64-simulator)     echo "tvos-arm64_x86_64-simulator" ;;
    *) echo "unknown slice: $1" >&2; exit 2 ;;
  esac
}

frameworkize() {
  # Wrap a single static archive + headers into a .framework directory tree
  # so xcodebuild -create-xcframework accepts it.
  local archive="$1" headers="$2" out_dir="$3" name="$4"
  rm -rf "$out_dir/$name.framework"
  mkdir -p "$out_dir/$name.framework/Headers" \
           "$out_dir/$name.framework/Modules"
  cp "$archive" "$out_dir/$name.framework/$name"
  if [[ -d "$headers" ]]; then
    cp -R "$headers"/* "$out_dir/$name.framework/Headers/" 2>/dev/null || true
  fi
  cat > "$out_dir/$name.framework/Modules/module.modulemap" <<EOF
framework module $name {
    umbrella header "$name.h"
    export *
    module * { export * }
}
EOF
}

for LIB in "${LIBS[@]}"; do
  ARGS=()
  CAP="$(echo "$LIB" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
  FW_NAME="Lib$CAP"
  for SLICE in "${SLICES[@]}"; do
    SID="$(slice_id "$SLICE")"
    PREFIX="$BUILD_DIR/$SLICE/prefix"
    ARCHIVE="$PREFIX/lib/lib${LIB}.a"
    if [[ ! -f "$ARCHIVE" ]]; then
      echo "  skip (missing): $LIB / $SLICE"
      continue
    fi
    FW_TMP="$BUILD_DIR/$SLICE/framework-staging"
    frameworkize "$ARCHIVE" "$PREFIX/include" "$FW_TMP" "$FW_NAME"
    ARGS+=("-framework" "$FW_TMP/$FW_NAME.framework")
  done

  if [[ "${#ARGS[@]}" -eq 0 ]]; then
    echo "  skip $FW_NAME — no slices built"
    continue
  fi

  rm -rf "$XCF_DIR/$FW_NAME.xcframework"
  xcodebuild -create-xcframework "${ARGS[@]}" -output "$XCF_DIR/$FW_NAME.xcframework"
done

# ── manifest ──────────────────────────────────────────────────────────────
MANIFEST="$XCF_DIR/MANIFEST.json"
{
  printf '{\n  "xcframeworks": [\n'
  FIRST=1
  for D in "$XCF_DIR"/*.xcframework; do
    [[ -d "$D" ]] || continue
    NAME="$(basename "$D" .xcframework)"
    SIZE="$(du -sk "$D" | awk '{print $1}')"
    SHA="$(find "$D" -type f -name '*.framework' -prune -o -type f -print | xargs shasum -a 256 | awk '{print $1}' | sort | shasum -a 256 | awk '{print $1}')"
    [[ $FIRST -eq 1 ]] || printf ',\n'
    printf '    {"name": "%s", "kb": %s, "sha256_dir": "%s"}' "$NAME" "$SIZE" "$SHA"
    FIRST=0
  done
  printf '\n  ]\n}\n'
} > "$MANIFEST"
echo "manifest: $MANIFEST"
