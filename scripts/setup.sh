#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

if [ -d "$PROJECT_DIR/GhosttyKit.xcframework" ]; then
  echo "==> Reusing existing ./GhosttyKit.xcframework"
  echo "==> Done"
  exit 0
fi

echo "==> Initializing ghostty submodule..."
git submodule update --init --recursive

if [ ! -d ghostty ]; then
  echo "==> ghostty submodule not present in index, cloning fallback checkout..."
  git clone --depth 1 --branch main https://github.com/manaflow-ai/ghostty.git ghostty
fi

if ! command -v zig >/dev/null 2>&1; then
  echo "Error: zig is not installed. Install via: brew install zig"
  exit 1
fi

if ! xcrun --sdk macosx metal -v >/dev/null 2>&1; then
  echo "Error: Metal compiler tools are unavailable in the active Xcode toolchain."
  echo "Install required Xcode components via: xcodebuild -runFirstLaunch"
  exit 1
fi

if [ ! -d ghostty ]; then
  echo "Error: ghostty submodule not found"
  exit 1
fi

GHOSTTY_SHA="$(git -C ghostty rev-parse HEAD)"
CACHE_ROOT="${IDX0_GHOSTTYKIT_CACHE_DIR:-$HOME/.cache/idx0/ghosttykit}"
CACHE_DIR="$CACHE_ROOT/$GHOSTTY_SHA"
CACHE_XCFRAMEWORK="$CACHE_DIR/GhosttyKit.xcframework"
LOCAL_XCFRAMEWORK="$PROJECT_DIR/ghostty/macos/GhosttyKit.xcframework"
LOCAL_SHA_STAMP="$LOCAL_XCFRAMEWORK/.ghostty_sha"
LOCK_DIR="$CACHE_ROOT/$GHOSTTY_SHA.lock"

mkdir -p "$CACHE_ROOT"

echo "==> Ghostty SHA: $GHOSTTY_SHA"

LOCK_TIMEOUT=300
LOCK_START=$SECONDS
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  if (( SECONDS - LOCK_START > LOCK_TIMEOUT )); then
    rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR"
    continue
  fi
  echo "==> Waiting for GhosttyKit cache lock..."
  sleep 1
done
trap 'rmdir "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT

if [ ! -d "$CACHE_XCFRAMEWORK" ]; then
  LOCAL_SHA=""
  if [ -f "$LOCAL_SHA_STAMP" ]; then
    LOCAL_SHA="$(cat "$LOCAL_SHA_STAMP")"
  fi

  if [ -d "$LOCAL_XCFRAMEWORK" ] && [ "$LOCAL_SHA" = "$GHOSTTY_SHA" ]; then
    echo "==> Reusing local GhosttyKit.xcframework"
  else
    echo "==> Building GhosttyKit.xcframework (this may take a few minutes)..."
    (
      cd ghostty
      # Keep flags cmux-compatible while avoiding local gettext/msgfmt dependency.
      # version-string avoids tag-shape panics in shallow/fallback clones.
      zig build -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=universal -Doptimize=ReleaseFast -Dversion-string=0.0.0 -Di18n=false
    )
    echo "$GHOSTTY_SHA" > "$LOCAL_SHA_STAMP"
  fi

  if [ ! -d "$LOCAL_XCFRAMEWORK" ]; then
    echo "Error: GhosttyKit.xcframework not found at $LOCAL_XCFRAMEWORK"
    exit 1
  fi

  TMP_DIR="$(mktemp -d "$CACHE_ROOT/.ghosttykit-tmp.XXXXXX")"
  mkdir -p "$CACHE_DIR"
  cp -R "$LOCAL_XCFRAMEWORK" "$TMP_DIR/GhosttyKit.xcframework"
  rm -rf "$CACHE_XCFRAMEWORK"
  mv "$TMP_DIR/GhosttyKit.xcframework" "$CACHE_XCFRAMEWORK"
  rmdir "$TMP_DIR"
  echo "==> Cached GhosttyKit.xcframework"
fi

echo "==> Creating symlink ./GhosttyKit.xcframework"
rm -rf GhosttyKit.xcframework
ln -sfn "$CACHE_XCFRAMEWORK" GhosttyKit.xcframework

echo "==> Done"
