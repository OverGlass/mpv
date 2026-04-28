#!/usr/bin/env bash
# build-slice.sh — build one library for one (sdk,arch) slice.
#
# Status: SKELETON — slice resolution and prefix layout are real; the
# per-library configure/build invocations are stubs with TODO markers
# where domain-specific iteration is required (especially: ffmpeg cross-
# compile flags for Catalyst+tvOS, libplacebo meson cross files,
# MoltenVK Xcode driver, mpv waf cross-compile).
#
# Usage: build-slice.sh <slice> <lib> <deps_dir> <slice_build_dir>

set -euo pipefail

SLICE="${1:?slice}"
LIB="${2:?lib}"
DEPS_DIR="$(cd "${3:?deps_dir}" && pwd)"
SLICE_DIR="$(mkdir -p "${4:?slice_build_dir}" && cd "$4" && pwd)"
APPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PREFIX="$SLICE_DIR/prefix"
LIB_BUILD="$SLICE_DIR/$LIB"
mkdir -p "$PREFIX/include" "$PREFIX/lib" "$LIB_BUILD"

# ── resolve slice → sdk + archs + min version ──────────────────────────────
case "$SLICE" in
  ios-arm64)
    SDK="iphoneos"
    ARCHS=("arm64")
    MIN_FLAG="-miphoneos-version-min=15.0"
    HOST_TRIPLE="aarch64-apple-darwin"
    ;;
  ios-arm64_x86_64-simulator)
    SDK="iphonesimulator"
    ARCHS=("arm64" "x86_64")
    MIN_FLAG="-mios-simulator-version-min=15.0"
    HOST_TRIPLE="aarch64-apple-darwin"  # changed per arch below
    ;;
  maccatalyst-arm64_x86_64)
    SDK="macosx"
    ARCHS=("arm64" "x86_64")
    MIN_FLAG="-target arm64-apple-ios15.0-macabi"  # changed per arch below
    HOST_TRIPLE="aarch64-apple-darwin"
    ;;
  tvos-arm64)
    SDK="appletvos"
    ARCHS=("arm64")
    MIN_FLAG="-mappletvos-version-min=15.0"
    HOST_TRIPLE="aarch64-apple-darwin"
    ;;
  tvos-arm64_x86_64-simulator)
    SDK="appletvsimulator"
    ARCHS=("arm64" "x86_64")
    MIN_FLAG="-mappletv-simulator-version-min=15.0"
    HOST_TRIPLE="aarch64-apple-darwin"
    ;;
  *)
    echo "unknown slice: $SLICE" >&2; exit 2 ;;
esac

SDK_PATH="$(xcrun --sdk "$SDK" --show-sdk-path)"
CC="$(xcrun --sdk "$SDK" -f clang)"
CXX="$(xcrun --sdk "$SDK" -f clang++)"

# Each library is built once per ARCH then lipo'd into a fat static lib.
# The per-lib functions below should append to per-arch dirs and lipo at
# the end. Implemented cleanly only for the trivially-cross-compilable libs;
# the harder ones (ffmpeg, mpv) need a per-arch loop with `--arch` flags.
#
# TODO — resolve per-arch builds + lipo. For now this scaffolds one arch.
ARCH="${ARCHS[0]}"
ARCH_FLAG="-arch $ARCH"
COMMON_CFLAGS="$ARCH_FLAG -isysroot $SDK_PATH $MIN_FLAG -fPIC"
COMMON_LDFLAGS="$ARCH_FLAG -isysroot $SDK_PATH $MIN_FLAG"

export CC CXX
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export CFLAGS="$COMMON_CFLAGS"
export CXXFLAGS="$COMMON_CFLAGS"
export LDFLAGS="$COMMON_LDFLAGS"

# Locate fetched source.
src_dir() {
  local name="$1"
  echo "$DEPS_DIR/$(ls "$DEPS_DIR" | grep "^$name-" | head -1)"
}

# Map our ARCH to meson's cpu_family.
case "$ARCH" in
  arm64)  CPU_FAMILY=aarch64; CPU=aarch64 ;;
  x86_64) CPU_FAMILY=x86_64;  CPU=x86_64 ;;
  *) echo "unknown arch: $ARCH" >&2; exit 2 ;;
esac

gen_meson_crossfile() {
  local out="$1"
  mkdir -p "$(dirname "$out")"
  cat > "$out" <<EOF
[binaries]
c = ['$CC']
cpp = ['$CXX']
ar = ['$(xcrun --sdk "$SDK" -f ar)']
strip = ['$(xcrun --sdk "$SDK" -f strip)']
pkg-config = ['$(command -v pkg-config)']

[built-in options]
c_args = [$(printf "'%s', " $CFLAGS | sed 's/, $//')]
c_link_args = [$(printf "'%s', " $LDFLAGS | sed 's/, $//')]
cpp_args = [$(printf "'%s', " $CXXFLAGS | sed 's/, $//')]
cpp_link_args = [$(printf "'%s', " $LDFLAGS | sed 's/, $//')]

[properties]
needs_exe_wrapper = true
sys_root = '$SDK_PATH'
pkg_config_libdir = '$PREFIX/lib/pkgconfig'

[host_machine]
system = 'darwin'
cpu_family = '$CPU_FAMILY'
cpu = '$CPU'
endian = 'little'
EOF
}

case "$LIB" in
  freetype)
    SRC="$(src_dir freetype)"
    cd "$LIB_BUILD"
    "$SRC/configure" \
      --host="$HOST_TRIPLE" \
      --prefix="$PREFIX" \
      --enable-static --disable-shared \
      --without-harfbuzz --without-bzip2 --without-png --without-zlib --without-brotli \
      || { echo "TODO: freetype cross-config for $SLICE/$ARCH"; exit 1; }
    make -j"$(sysctl -n hw.ncpu)" install
    ;;

  fribidi)
    SRC="$(src_dir fribidi)"
    gen_meson_crossfile "$LIB_BUILD/cross.ini"
    meson setup "$LIB_BUILD/build" "$SRC" \
      --cross-file "$LIB_BUILD/cross.ini" \
      --prefix="$PREFIX" \
      --buildtype=release \
      --default-library=static \
      -Dtests=false -Ddocs=false -Dbin=false
    meson install -C "$LIB_BUILD/build"
    ;;

  harfbuzz)
    SRC="$(src_dir harfbuzz)"
    gen_meson_crossfile "$LIB_BUILD/cross.ini"
    # Depends on freetype.
    meson setup "$LIB_BUILD/build" "$SRC" \
      --cross-file "$LIB_BUILD/cross.ini" \
      --prefix="$PREFIX" \
      --buildtype=release \
      --default-library=static \
      -Dtests=disabled -Ddocs=disabled -Dutilities=disabled \
      -Dfreetype=enabled -Dcairo=disabled -Dchafa=disabled \
      -Dglib=disabled -Dgobject=disabled -Dicu=disabled
    meson install -C "$LIB_BUILD/build"
    ;;

  libunibreak)
    SRC="$(src_dir libunibreak)"
    cd "$LIB_BUILD"
    "$SRC/configure" --host="$HOST_TRIPLE" --prefix="$PREFIX" --enable-static --disable-shared
    make -j"$(sysctl -n hw.ncpu)" install
    ;;

  libass)
    SRC="$(src_dir libass)"
    gen_meson_crossfile "$LIB_BUILD/cross.ini"
    # Depends on freetype + fribidi + harfbuzz + libunibreak.
    meson setup "$LIB_BUILD/build" "$SRC" \
      --cross-file "$LIB_BUILD/cross.ini" \
      --prefix="$PREFIX" \
      --buildtype=release \
      --default-library=static \
      -Dtest=disabled -Dprofile=disabled -Dcompare=disabled -Dfuzz=disabled \
      -Dfontconfig=disabled -Dcoretext=enabled -Ddirectwrite=disabled \
      -Drequire-system-font-provider=true -Dlibunibreak=enabled
    meson install -C "$LIB_BUILD/build"
    ;;

  lcms2)
    SRC="$(src_dir lcms2)"
    cd "$LIB_BUILD"
    "$SRC/configure" --host="$HOST_TRIPLE" --prefix="$PREFIX" --enable-static --disable-shared
    make -j"$(sysctl -n hw.ncpu)" install
    ;;

  MoltenVK)
    # TODO: MoltenVK ships its own Xcode-driven build. Run fetchDependencies + ./Scripts/build-mvk.sh
    # then copy MoltenVK.xcframework slices into our prefix-equivalent tree.
    echo "TODO: MoltenVK build integration for $SLICE"
    exit 1
    ;;

  ffmpeg)
    SRC="$(src_dir ffmpeg)"
    cd "$LIB_BUILD"
    # TODO: real cross-compile invocation. Sketch:
    #   "$SRC/configure" \
    #     --target-os=darwin \
    #     --arch="$ARCH" \
    #     --cc="$CC" \
    #     --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS" \
    #     --enable-cross-compile \
    #     --prefix="$PREFIX" \
    #     --disable-programs --disable-doc \
    #     --enable-pic --enable-static --disable-shared \
    #     --enable-videotoolbox \
    #     --enable-libdav1d \
    #     --disable-network  # we use NSURLSession-fronted IO
    echo "TODO: ffmpeg cross-build for $SLICE/$ARCH"
    exit 1
    ;;

  libplacebo)
    # TODO: meson cross + -Dvulkan=enabled -Dshaderc=enabled. Depends on MoltenVK headers.
    echo "TODO: libplacebo meson cross-build for $SLICE/$ARCH"
    exit 1
    ;;

  mpv)
    SRC="$(cd "$APPLE_DIR/.." && pwd)"   # mpv source = the repo we're in
    cd "$LIB_BUILD"
    # mpv uses meson. TODO: real meson invocation. Sketch:
    #   meson setup "$SRC" \
    #     --cross-file=<generated> \
    #     --prefix="$PREFIX" \
    #     -Dlibmpv=true -Dcplayer=false -Dgpl=true \
    #     -Davfoundation=enabled \   # ships ao_avfoundation; Phase 2 of plan
    #     -Daudiounit=enabled \      # passthrough fallback (SPDIF, etc.)
    #     -Dvulkan=enabled           # required by Phase 0c (MPV_RENDER_API_TYPE_VK)
    #
    # Notes for the implementer:
    # - Phase 2 of the plan was originally going to add a custom AO (ao_coreaudio_avaudioengine).
    #   That's no longer needed — upstream's ao_avfoundation does what we want once we pass
    #   -Davfoundation=enabled. MPVKit 0.41.0 didn't enable it; that was the only reason
    #   the consumer was stuck on ao_audiounit + workarounds. See plan §Phase 2 (revised).
    # - Phase 0c's MPV_RENDER_API_TYPE_VK is exposed via this libmpv build automatically once
    #   features['vulkan'] resolves true (depends on libplacebo + vulkan dep being present in
    #   the cross prefix).
    echo "TODO: mpv meson cross-build for $SLICE/$ARCH"
    exit 1
    ;;

  *)
    echo "unknown lib: $LIB" >&2; exit 2 ;;
esac

echo "  ok: $LIB / $SLICE / $ARCH"
