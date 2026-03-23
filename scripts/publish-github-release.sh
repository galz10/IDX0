#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

DEFAULT_VERSION="$(awk '/MARKETING_VERSION:/ {print $2; exit}' project.yml 2>/dev/null || true)"
if [[ -z "${DEFAULT_VERSION:-}" ]]; then
  DEFAULT_VERSION="0.0.1"
fi

VERSION="$DEFAULT_VERSION"
DIST_DIR="$ROOT_DIR/dist"
REPO=""
TITLE=""
TARGET_REF=""
NOTES_FILE=""
GENERATE_NOTES=1
MAKE_DRAFT=1
PRERELEASE=0
OPEN_WEB=0
PUSH_TAG=1

usage() {
  cat <<'EOF'
Create or update a GitHub release and upload dist artifacts.

Usage:
  ./scripts/publish-github-release.sh [options]

Options:
  --version <semver>          Release version. Defaults to MARKETING_VERSION from project.yml.
  --dist-dir <dir>            Artifact directory. Default: ./dist
  --repo <owner/name>         GitHub repo (falls back to current gh repo context)
  --title <text>              Release title. Default: "IDX0 v<version>"
  --target <ref>              Git ref/sha used if a new tag is created (default: current HEAD)
  --notes-file <path>         Markdown notes file to use for release body
  --no-generate-notes         Disable --generate-notes when creating a new release
  --publish                   Create release as published (not draft)
  --prerelease                Mark release as prerelease
  --no-push-tag               Do not push tag to origin
  --open                      Open the release page in browser after create/update
  -h, --help                  Show this help text

Expected artifacts:
  IDX0-<version>.dmg
  IDX0-<version>-mac.zip
  IDX0-<version>-mac.tar.gz
  SHA256SUMS.txt
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: required command not found: $cmd" >&2
    exit 1
  fi
}

normalize_version() {
  local raw="$1"
  raw="${raw#v}"
  echo "$raw"
}

resolve_artifact_path() {
  local preferred="$1"
  local fallback="$2"
  if [[ -f "$preferred" ]]; then
    echo "$preferred"
    return 0
  fi
  if [[ -f "$fallback" ]]; then
    echo "$fallback"
    return 0
  fi
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --dist-dir)
      DIST_DIR="${2:-}"
      shift 2
      ;;
    --repo)
      REPO="${2:-}"
      shift 2
      ;;
    --title)
      TITLE="${2:-}"
      shift 2
      ;;
    --target)
      TARGET_REF="${2:-}"
      shift 2
      ;;
    --notes-file)
      NOTES_FILE="${2:-}"
      shift 2
      ;;
    --no-generate-notes)
      GENERATE_NOTES=0
      shift
      ;;
    --publish)
      MAKE_DRAFT=0
      shift
      ;;
    --prerelease)
      PRERELEASE=1
      shift
      ;;
    --no-push-tag)
      PUSH_TAG=0
      shift
      ;;
    --open)
      OPEN_WEB=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

VERSION="$(normalize_version "$VERSION")"
if [[ -z "$VERSION" ]]; then
  echo "error: version is empty" >&2
  exit 1
fi

TAG="v$VERSION"
if [[ -z "$TITLE" ]]; then
  TITLE="IDX0 v$VERSION"
fi

DIST_DIR="$(cd "$DIST_DIR" 2>/dev/null && pwd || true)"
if [[ -z "$DIST_DIR" || ! -d "$DIST_DIR" ]]; then
  echo "error: dist directory not found: ${DIST_DIR:-<unresolved>}" >&2
  exit 1
fi

require_cmd git
require_cmd gh

if ! gh auth status >/dev/null 2>&1; then
  echo "error: GitHub CLI is not authenticated." >&2
  echo "hint: run 'gh auth login' first." >&2
  exit 1
fi

if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
fi

DMG_PATH="$(resolve_artifact_path "$DIST_DIR/IDX0-${VERSION}.dmg" "$DIST_DIR/idx0-${VERSION}.dmg" || true)"
ZIP_PATH="$(resolve_artifact_path "$DIST_DIR/IDX0-${VERSION}-mac.zip" "$DIST_DIR/idx0-${VERSION}-mac.zip" || true)"
TAR_PATH="$(resolve_artifact_path "$DIST_DIR/IDX0-${VERSION}-mac.tar.gz" "$DIST_DIR/idx0-${VERSION}-mac.tar.gz" || true)"
CHECKSUM_PATH="$DIST_DIR/SHA256SUMS.txt"

for artifact in "$DMG_PATH" "$ZIP_PATH" "$TAR_PATH" "$CHECKSUM_PATH"; do
  if [[ -z "$artifact" || ! -f "$artifact" ]]; then
    echo "error: missing artifact: $artifact" >&2
    exit 1
  fi
done

if [[ -n "$NOTES_FILE" && ! -f "$NOTES_FILE" ]]; then
  echo "error: notes file not found: $NOTES_FILE" >&2
  exit 1
fi

if [[ "$PUSH_TAG" -eq 1 ]]; then
  if ! git rev-parse "$TAG" >/dev/null 2>&1; then
    if [[ -n "$TARGET_REF" ]]; then
      git tag -a "$TAG" "$TARGET_REF" -m "IDX0 $TAG"
    else
      git tag -a "$TAG" -m "IDX0 $TAG"
    fi
    echo "==> Created local tag: $TAG"
  else
    echo "==> Local tag already exists: $TAG"
  fi

  if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    echo "==> Remote tag already exists: origin/$TAG"
  else
    git push origin "$TAG"
    echo "==> Pushed tag to origin: $TAG"
  fi
else
  echo "==> Skipping tag push (--no-push-tag)"
fi

ASSETS=("$DMG_PATH" "$ZIP_PATH" "$TAR_PATH" "$CHECKSUM_PATH")

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "==> Release exists, uploading assets with --clobber"
  gh release upload "$TAG" "${ASSETS[@]}" --repo "$REPO" --clobber
else
  echo "==> Creating new release: $TAG"
  CREATE_ARGS=("$TAG" "${ASSETS[@]}" --repo "$REPO" --title "$TITLE")

  if [[ "$MAKE_DRAFT" -eq 1 ]]; then
    CREATE_ARGS+=(--draft)
  fi

  if [[ "$PRERELEASE" -eq 1 ]]; then
    CREATE_ARGS+=(--prerelease)
  fi

  if [[ -n "$TARGET_REF" ]]; then
    CREATE_ARGS+=(--target "$TARGET_REF")
  fi

  if [[ -n "$NOTES_FILE" ]]; then
    CREATE_ARGS+=(--notes-file "$NOTES_FILE")
  elif [[ "$GENERATE_NOTES" -eq 1 ]]; then
    CREATE_ARGS+=(--generate-notes)
  fi

  gh release create "${CREATE_ARGS[@]}"
fi

echo
echo "==> Release ready"
echo "Repo: $REPO"
echo "Tag: $TAG"
echo "Assets:"
printf ' - %s\n' "$DMG_PATH" "$ZIP_PATH" "$TAR_PATH" "$CHECKSUM_PATH"

if [[ "$OPEN_WEB" -eq 1 ]]; then
  gh release view "$TAG" --repo "$REPO" --web
fi
