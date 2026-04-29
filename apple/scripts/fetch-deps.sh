#!/usr/bin/env bash
# fetch-deps.sh — pin + download all external sources into <deps_dir>.
#
# Idempotent. Versions live in apple/scripts/deps-lock.json. Tarballs are
# verified against sha256 (TODO_FILL_ON_FIRST_BUILD until the first
# successful run captures them). Git deps are checked out at the pinned ref.
#
# Usage: fetch-deps.sh <deps_dir>

set -euo pipefail

DEPS_DIR="${1:?usage: fetch-deps.sh <deps_dir>}"
APPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$APPLE_DIR/scripts/deps-lock.json"

require_tool() { command -v "$1" >/dev/null || { echo "missing $1"; exit 1; }; }
require_tool jq
require_tool curl
require_tool tar
require_tool git
require_tool shasum

mkdir -p "$DEPS_DIR"

# Each entry has either {url, sha256} (tarball) or {url, ref} (git).
NAMES="$(jq -r 'keys[] | select(. != "$schema")' "$LOCK")"

for NAME in $NAMES; do
  VERSION="$(jq -r --arg n "$NAME" '.[$n].version' "$LOCK")"
  URL="$(jq -r --arg n "$NAME" '.[$n].url' "$LOCK")"
  REF="$(jq -r --arg n "$NAME" '.[$n].ref // empty' "$LOCK")"
  SHA="$(jq -r --arg n "$NAME" '.[$n].sha256 // empty' "$LOCK")"
  TARGET="$DEPS_DIR/$NAME-$VERSION"

  # `touch` creates a regular file, so check `-f` not `-d`.
  if [[ -f "$TARGET/.fetched" ]]; then
    echo "  [cache] $NAME-$VERSION"
    continue
  fi

  if [[ -n "$REF" ]]; then
    # git clone
    echo "  [clone] $NAME-$VERSION ($REF)"
    rm -rf "$TARGET"
    git clone --depth 1 --branch "$REF" --recurse-submodules "$URL" "$TARGET"
  else
    # tarball
    TARBALL="$DEPS_DIR/$NAME-$VERSION.${URL##*.}"
    if [[ ! -f "$TARBALL" ]]; then
      echo "  [fetch] $NAME-$VERSION"
      curl -fsSL --retry 5 --retry-all-errors -o "$TARBALL" "$URL"
    fi
    if [[ "$SHA" != "TODO_FILL_ON_FIRST_BUILD" ]]; then
      echo "$SHA  $TARBALL" | shasum -a 256 -c - >/dev/null
    else
      echo "  WARN: $NAME has placeholder sha256; capture: $(shasum -a 256 "$TARBALL" | awk '{print $1}')"
    fi
    rm -rf "$TARGET"
    mkdir -p "$TARGET"
    tar -xf "$TARBALL" -C "$TARGET" --strip-components=1
  fi

  # Apply any patches we ship for this dep, in lexicographic order. Patches
  # live under `apple/patches/<name>/*.patch` and are applied with `-p1`
  # against `$TARGET`. Idempotent because we only run when the dep was just
  # (re-)extracted — a successful fetch implies pristine source.
  PATCH_DIR="$APPLE_DIR/patches/$NAME"
  if [[ -d "$PATCH_DIR" ]]; then
    for PATCH in "$PATCH_DIR"/*.patch; do
      [[ -e "$PATCH" ]] || continue
      echo "  [patch] $NAME-$VERSION <- ${PATCH##*/}"
      (cd "$TARGET" && patch -p1 --forward --silent < "$PATCH") \
        || { echo "    failed applying $PATCH"; exit 1; }
    done
  fi

  touch "$TARGET/.fetched"
done

echo "fetch-deps complete."
