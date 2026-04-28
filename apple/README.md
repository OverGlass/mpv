# mpv-apple

Hard fork of [mpv](https://github.com/mpv-player/mpv) maintained by the Jellyfuse team to ship Apple-platform features that don't (yet) exist in upstream:

1. **`MPV_RENDER_API_TYPE_VK`** — a Vulkan render API on the public `mpv_render_*` surface, for embedding mpv into externally-managed Metal/Vulkan textures (drives the iOS/Catalyst/tvOS Metal pipeline in [Jellyfuse](https://github.com/<jellyfuse>/jellyfuse) via MoltenVK).
2. **`ao_coreaudio_avaudioengine`** — an `AVAudioEngine`-based audio output that plays nicely with `AVAudioSession` lifecycle (no silent-primer / no `audio-exclusive=yes` workarounds required to qualify for Now Playing).

Everything else tracks upstream master, rebased weekly.

## Branch model

| Branch | Purpose |
|---|---|
| `upstream/master` (remote) | Authoritative upstream `mpv-player/mpv` |
| `apple/main` | Our shipping branch. Linear, rebased weekly on `upstream/master`. Each Apple-specific change is a single commit. |

```
upstream/master ─o─o─o─o─o─o─o─o─o─o
                                    \
                                     o   patch: ao_coreaudio_avaudioengine
                                      \
apple/main                             o   patch: MPV_RENDER_API_TYPE_VK
                                        \
                                         o   chore: apple build scripts
```

Every release tag is `apple/vX.Y.Z-jf.N` where `vX.Y.Z` is the upstream version we're sitting on top of and `N` increments per Apple-side iteration on the same upstream base.

## Repo layout (Apple additions only)

```
apple/
├── README.md                          (this file)
├── scripts/
│   ├── build.sh                       Master entry — runs fetch + build + package
│   ├── fetch-deps.sh                  Pins + fetches ffmpeg, libplacebo, MoltenVK, libass, fribidi, freetype, harfbuzz, libunibreak, lcms2
│   ├── build-slice.sh                 Builds one (sdk,arch) slice end-to-end
│   └── package-xcframeworks.sh        lipo + xcodebuild -create-xcframework, emits build/xcframeworks/
└── patches/                           git format-patch upstream/master..apple/main, regenerated on tag for review

.github/workflows/
└── apple-release.yml                  Triggers on tag apple/v* — builds + attaches xcframeworks to the GH release
```

## Slices produced

| Slice | Targets | XCFramework slice name |
|---|---|---|
| `ios-arm64` | iPhone, iPad, Apple TV (device) | `ios-arm64` |
| `ios-arm64_x86_64-simulator` | iOS / iPadOS / tvOS simulator | `ios-arm64_x86_64-simulator` |
| `maccatalyst-arm64_x86_64` | Mac Catalyst | `ios-arm64_x86_64-maccatalyst` |
| `tvos-arm64` | Apple TV (device) | `tvos-arm64` |
| `tvos-arm64_x86_64-simulator` | tvOS simulator | `tvos-arm64_x86_64-simulator` |

## Libraries built

| Library | Why it ships |
|---|---|
| `libmpv` | core |
| `libavcodec`, `libavformat`, `libavfilter`, `libavutil`, `libswresample`, `libswscale` | ffmpeg (codecs incl. VideoToolbox + dav1d statically) |
| `libplacebo` | Renderer used by `vo=gpu-next` (HDR, scaling, dithering) |
| `MoltenVK` | Vulkan-on-Metal layer (target of libplacebo's Vulkan backend) |
| `libass`, `libfreetype`, `libfribidi`, `libharfbuzz`, `libunibreak` | High-quality SSA/ASS subtitle rendering |
| `liblcms2` | ICC profile handling for libplacebo |

We deliberately do **not** ship: `libopenssl`/`libgnutls` (TLS via `Security.framework`), `libsmbclient`, `libbluray`, `libuavs3d`, `libdovi` (deferred to a Dolby Vision phase), `libluajit`, `libuchardet`, `libdav1d` (compiled into ffmpeg, not standalone).

## Local build prerequisites

You need a Mac (arm64 or Intel) with:

- Xcode 15+ (`xcode-select --install` is not enough — full Xcode required)
- Homebrew packages: `meson`, `ninja`, `nasm`, `pkg-config`, `automake`, `autoconf`, `libtool`
- Python 3.11+
- Disk: ~10 GB free for build artifacts

```bash
brew install meson ninja nasm pkg-config automake autoconf libtool
```

Then:

```bash
./apple/scripts/build.sh                                  # full matrix, ~25 min on M-series
./apple/scripts/build.sh --slice ios-arm64                # single slice for iteration
./apple/scripts/build.sh --slice ios-arm64 --lib libplacebo  # one lib in one slice
```

Output: `build/xcframeworks/Lib*.xcframework/`.

## CI

`.github/workflows/apple-release.yml` runs on tag push matching `apple/v*`. It:
1. Builds the full matrix on `macos-14`.
2. Caches `build/deps/` keyed on `(deps-lock.json hash, runner image)`.
3. Packages each `.xcframework` as a `.zip`.
4. Generates `MANIFEST.json` (SHA256 + size per asset).
5. Creates a GH release with all `.zip` and the manifest as assets.

Consumer side ([Jellyfuse](https://github.com/<jellyfuse>/jellyfuse)) downloads + verifies via `modules/native-mpv/scripts/fetch-libmpv.sh`.

## Adding a patch

```bash
# Make sure apple/main is up to date with upstream.
git fetch upstream
git rebase upstream/master apple/main

# Make your change as one focused commit.
git checkout apple/main
# ... edit code ...
git add -A
git commit -m "<subsystem>: <what changed>"

# Test build locally.
./apple/scripts/build.sh --slice ios-arm64

# Push (after fork is published).
git push origin apple/main
```

Every commit on `apple/main` should be self-contained and rebase cleanly. If a change requires multiple commits for clarity, that's fine, but each must compile on its own.

## Upstreaming candidates

The Vulkan render API patch (`MPV_RENDER_API_TYPE_VK`) is intentionally written as a clean, minimal extension of the existing render-api shape. It is a candidate for upstreaming once stable — proposing it back upstream would reduce our long-term rebase tax to roughly zero.

## License

Same as upstream mpv: GPL-2.0-or-later (or LGPL-2.1-or-later when configured with `--disable-gpl`). The Apple-specific scripts and `ao_coreaudio_avaudioengine.m` are contributed under the same terms.
