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
# Pin Python to 3.13: 3.14's xml.etree.ElementTree API change breaks
# libplacebo's gen.py (and probably other code generators we'll meet).
python = ['$(command -v python3.11 || command -v python3.13 || command -v python3)']

[built-in options]
c_args = [$(printf "'%s', " $CFLAGS | sed 's/, $//')]
c_link_args = [$(printf "'%s', " $LDFLAGS | sed 's/, $//')]
cpp_args = [$(printf "'%s', " $CXXFLAGS | sed 's/, $//')]
cpp_link_args = [$(printf "'%s', " $LDFLAGS | sed 's/, $//')]

[properties]
needs_exe_wrapper = true
# Intentionally NOT setting sys_root: meson rewrites absolute -I paths it
# receives from pkg-config to be sys_root-relative, which mangles our
# host-side $PREFIX/include into $SDK_PATH$PREFIX/include. -isysroot is
# already passed via c_args/c_link_args; that's sufficient for clang to
# find SDK headers without polluting pkg-config-supplied include paths.
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
    # NOTE: macOS 26+ syspolicyd serialises every libtool wrapper launch, which
    # destroys parallel make for autotools libs (each spawn waits on the daemon).
    # Run serial here — slower per-file but avoids pile-up. Pre-warm the wrapper
    # so the first launch cost doesn't dominate.
    "$LIB_BUILD/libtool" --version >/dev/null 2>&1 || true
    make -j1 install
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
    # See freetype block re: macOS 26 syspolicyd / libtool serialisation.
    "$LIB_BUILD/libtool" --version >/dev/null 2>&1 || true
    make -j1 install
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
    # See freetype block re: macOS 26 syspolicyd / libtool serialisation.
    "$LIB_BUILD/libtool" --version >/dev/null 2>&1 || true
    make -j1 install
    ;;

  MoltenVK)
    SRC="$(src_dir MoltenVK)"
    # MoltenVK has its own Xcode-driven build. Map our slice to its
    # Makefile target + xcframework slice id.
    case "$SLICE" in
      ios-arm64)                       MVK_TARGET=ios;     MVK_SLICE=ios-arm64 ;;
      ios-arm64_x86_64-simulator)      MVK_TARGET=iossim;  MVK_SLICE=ios-arm64_x86_64-simulator ;;
      maccatalyst-arm64_x86_64)        MVK_TARGET=maccat;  MVK_SLICE=ios-arm64_x86_64-maccatalyst ;;
      tvos-arm64)                      MVK_TARGET=tvos;    MVK_SLICE=tvos-arm64 ;;
      tvos-arm64_x86_64-simulator)     MVK_TARGET=tvossim; MVK_SLICE=tvos-arm64_x86_64-simulator ;;
      *) echo "MoltenVK: unhandled slice $SLICE" >&2; exit 2 ;;
    esac
    # fetchDependencies pulls SPIRV-Cross, glslang, SPIRV-Tools, Vulkan-Headers
    # into the MoltenVK source tree. We let it cache between builds via a
    # marker file so re-runs of the slice loop don't re-fetch every time.
    if [[ ! -f "$SRC/.deps-fetched-$MVK_TARGET" ]]; then
      (cd "$SRC" && ./fetchDependencies "--$MVK_TARGET")
      touch "$SRC/.deps-fetched-$MVK_TARGET"
    fi
    (cd "$SRC" && make "$MVK_TARGET")
    # The Makefile drops outputs into Package/Release/MoltenVK/. We copy
    # the static archive + headers into our prefix so downstream consumers
    # (libplacebo, mpv) can resolve -lMoltenVK and #include <MoltenVK/...>.
    MVK_LIB="$SRC/Package/Release/MoltenVK/static/MoltenVK.xcframework/$MVK_SLICE/libMoltenVK.a"
    MVK_HDR="$SRC/Package/Release/MoltenVK/include"
    if [[ ! -f "$MVK_LIB" ]]; then
      echo "MoltenVK: expected $MVK_LIB after build, not found"
      ls -la "$SRC/Package/Release/MoltenVK/static/MoltenVK.xcframework/" 2>/dev/null || true
      exit 1
    fi
    install -m 644 "$MVK_LIB" "$PREFIX/lib/libMoltenVK.a"
    cp -R "$MVK_HDR/MoltenVK" "$PREFIX/include/" 2>/dev/null || true
    # Synthesize vulkan.pc so mpv's `dependency('vulkan')` resolves. The
    # headers come from libplacebo's bundled Vulkan-Headers (already on the
    # libplacebo include path); the loader is statically linked from our
    # prefix's libMoltenVK.a.
    VK_HEADERS_DIR="$DEPS_DIR/$(ls "$DEPS_DIR" | grep '^libplacebo-' | head -1)/3rdparty/Vulkan-Headers/include"
    mkdir -p "$PREFIX/lib/pkgconfig"
    cat > "$PREFIX/lib/pkgconfig/vulkan.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
includedir=$VK_HEADERS_DIR
libdir=\${prefix}/lib

Name: Vulkan-Loader
Description: Vulkan loader (MoltenVK on Apple platforms)
Version: 1.3.296
Libs: -L\${libdir} -lMoltenVK -framework Metal -framework Foundation -framework QuartzCore -framework IOSurface
Cflags: -I\${includedir}
EOF
    echo "  ok: MoltenVK / $SLICE / $ARCH"
    ;;

  ffmpeg)
    SRC="$(src_dir ffmpeg)"
    cd "$LIB_BUILD"
    # ffmpeg doesn't use autotools or meson — its own ./configure has the
    # cross-compile flags. It also doesn't go through libtool wrappers,
    # so parallel make is safe (no syspolicyd pile-up).
    #
    # We KEEP network support: libmpv uses ffmpeg's demuxer to play HTTP(S)
    # streams from Jellyfin. TLS via SecureTransport (Security.framework),
    # so no openssl/gnutls needed in the link graph.
    #
    # We disable encoders, muxers, programs, docs — playback-only client.
    # Decoders/demuxers/parsers/protocols stay default (autodetect) so we
    # don't have to enumerate the full list a Jellyfin client might see.
    "$SRC/configure" \
      --prefix="$PREFIX" \
      --target-os=darwin \
      --arch="$ARCH" \
      --enable-cross-compile \
      --cc="$CC" \
      --cxx="$CXX" \
      --extra-cflags="$CFLAGS" \
      --extra-ldflags="$LDFLAGS" \
      --enable-static \
      --disable-shared \
      --enable-pic \
      --enable-gpl \
      --disable-programs \
      --disable-doc \
      --disable-debug \
      --disable-encoders \
      --disable-muxers \
      --disable-avdevice \
      --enable-videotoolbox \
      --enable-audiotoolbox \
      --enable-securetransport \
      --pkg-config-flags="--static" \
      --pkg-config="$(command -v pkg-config)"
    make -j"$(sysctl -n hw.ncpu)" install
    ;;

  libplacebo)
    SRC="$(src_dir libplacebo)"
    gen_meson_crossfile "$LIB_BUILD/cross.ini"
    # libplacebo bundles Vulkan-Headers under 3rdparty/, so we don't need a
    # system Vulkan SDK on the host. We disable demos/tests, the OpenGL and
    # D3D11 backends, and shaderc/glslang on first pass — libplacebo can
    # operate without runtime shader compilation for the modes mpv uses.
    # Dolby Vision deferred per plan §HDR scope v2.
    meson setup "$LIB_BUILD/build" "$SRC" \
      --cross-file "$LIB_BUILD/cross.ini" \
      --prefix="$PREFIX" \
      --buildtype=release \
      --default-library=static \
      -Dvulkan=enabled \
      -Dvk-proc-addr=disabled \
      -Dopengl=disabled \
      -Dd3d11=disabled \
      -Dglslang=disabled \
      -Dshaderc=disabled \
      -Dlcms=enabled \
      -Ddovi=disabled \
      -Dlibdovi=disabled \
      -Ddemos=false \
      -Dtests=false
    meson install -C "$LIB_BUILD/build"
    ;;

  mpv)
    SRC="$(cd "$APPLE_DIR/.." && pwd)"   # mpv source = the repo we're in
    gen_meson_crossfile "$LIB_BUILD/cross.ini"
    # libmpv-only build for an iOS/Catalyst/tvOS Jellyfin client.
    # - libmpv=true / cplayer=false: we only ship the library
    # - avfoundation+audiounit: AVSampleBufferAudioRenderer first, audiounit as
    #   bitstream-passthrough fallback (Phase 2)
    # - vulkan + videotoolbox-pl: feeds Phase 0c's MPV_RENDER_API_TYPE_VK via
    #   libplacebo. videotoolbox-gl is left disabled — we're done with GLES.
    # - libass + lcms2 enabled because we have them in $PREFIX
    # - everything Linux/Windows-only (x11, wayland, drm, gbm, alsa, pulse,
    #   jack, sdl2, openal) explicitly disabled even though "auto" wouldn't
    #   pick them up cross-compiling — keeps configure output clean
    # - lua, javascript, libarchive, vapoursynth, rubberband, uchardet,
    #   subrandr, zimg, jpeg, libavdevice, libbluray, cdda, dvbin, dvdnav,
    #   coreaudio (macOS-only), gl* — all disabled for binary size
    meson setup "$LIB_BUILD/build" "$SRC" \
      --cross-file "$LIB_BUILD/cross.ini" \
      --prefix="$PREFIX" \
      --buildtype=release \
      --default-library=static \
      -Dlibmpv=true \
      -Dcplayer=false \
      -Dgpl=true \
      -Davfoundation=enabled \
      -Daudiounit=enabled \
      -Dcoreaudio=disabled \
      -Dvulkan=enabled \
      -Dvideotoolbox-pl=enabled \
      -Dvideotoolbox-gl=disabled \
      -Dgl=disabled \
      -Dgl-cocoa=disabled \
      -Dlcms2=enabled \
      -Dtests=false \
      -Dfuzzers=false \
      -Dmanpage-build=disabled \
      -Dhtml-build=disabled \
      -Dcdda=disabled \
      -Ddvbin=disabled \
      -Ddvdnav=disabled \
      -Diconv=enabled \
      -Djavascript=disabled \
      -Djpeg=disabled \
      -Dlibarchive=disabled \
      -Dlibavdevice=disabled \
      -Dlibbluray=disabled \
      -Dlua=disabled \
      -Drubberband=disabled \
      -Dsubrandr=disabled \
      -Duchardet=disabled \
      -Dvapoursynth=disabled \
      -Dzimg=disabled \
      -Dzlib=enabled \
      -Dpulse=disabled \
      -Dalsa=disabled \
      -Djack=disabled \
      -Dopenal=disabled \
      -Dsdl2=disabled \
      -Dsdl2-audio=disabled \
      -Dsdl2-video=disabled \
      -Dx11=disabled \
      -Dwayland=disabled \
      -Ddrm=disabled \
      -Dgbm=disabled
    meson install -C "$LIB_BUILD/build"
    ;;

  *)
    echo "unknown lib: $LIB" >&2; exit 2 ;;
esac

echo "  ok: $LIB / $SLICE / $ARCH"
