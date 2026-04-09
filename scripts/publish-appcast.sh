#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

VERSION=""
ZIP_PATH=""
APPCAST_REPO=""
DOWNLOAD_BASE_URL=""
BRANCH="main"
TITLE="IDX0"
MIN_SYSTEM_VERSION="14.0"
SIGNATURE=""
PRERELEASE=0
NO_PUSH=0

usage() {
  cat <<'USAGE'
Publish IDX0 appcast content to a dedicated appcast repository.

Usage:
  ./scripts/publish-appcast.sh --version <semver> --zip <path> --appcast-repo <git-url> --download-base-url <url> [options]

Options:
  --version <semver>              Version string (for example: 0.2.0)
  --zip <path>                    Notarized zip artifact path
  --appcast-repo <git-url>        Destination git repository URL for appcast hosting
  --download-base-url <url>       Public base URL used in appcast enclosure URLs
  --branch <name>                 Destination branch. Default: main
  --title <text>                  App title in appcast items. Default: IDX0
  --minimum-system-version <ver>  Sparkle minimum system version. Default: 14.0
  --signature <sig>               Optional Sparkle EdDSA signature for the zip
  --prerelease                    Mark this entry as prerelease (excluded from stable appcast by default)
  --no-push                       Commit locally in clone but skip push
  -h, --help                      Show help text
USAGE
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: required command not found: $cmd" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --zip)
      ZIP_PATH="${2:-}"
      shift 2
      ;;
    --appcast-repo)
      APPCAST_REPO="${2:-}"
      shift 2
      ;;
    --download-base-url)
      DOWNLOAD_BASE_URL="${2:-}"
      shift 2
      ;;
    --branch)
      BRANCH="${2:-}"
      shift 2
      ;;
    --title)
      TITLE="${2:-}"
      shift 2
      ;;
    --minimum-system-version)
      MIN_SYSTEM_VERSION="${2:-}"
      shift 2
      ;;
    --signature)
      SIGNATURE="${2:-}"
      shift 2
      ;;
    --prerelease)
      PRERELEASE=1
      shift
      ;;
    --no-push)
      NO_PUSH=1
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

if [[ -z "$VERSION" || -z "$ZIP_PATH" || -z "$APPCAST_REPO" || -z "$DOWNLOAD_BASE_URL" ]]; then
  echo "error: --version, --zip, --appcast-repo, and --download-base-url are required" >&2
  usage
  exit 1
fi

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "error: zip artifact not found: $ZIP_PATH" >&2
  exit 1
fi

require_cmd git
require_cmd python3

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "==> Cloning appcast repo"
git clone --branch "$BRANCH" --single-branch "$APPCAST_REPO" "$TMP_DIR/repo"

REPO_DIR="$TMP_DIR/repo"
ARCHIVE_DIR="$REPO_DIR/archives"
mkdir -p "$ARCHIVE_DIR"

ZIP_FILENAME="IDX0-${VERSION}-mac.zip"
TARGET_ZIP="$ARCHIVE_DIR/$ZIP_FILENAME"
cp "$ZIP_PATH" "$TARGET_ZIP"

ZIP_SIZE="$(stat -f%z "$TARGET_ZIP")"
PUB_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DOWNLOAD_URL="${DOWNLOAD_BASE_URL%/}/archives/$ZIP_FILENAME"
MANIFEST_PATH="$REPO_DIR/releases.json"

if [[ ! -f "$MANIFEST_PATH" ]]; then
  echo "[]" > "$MANIFEST_PATH"
fi

python3 - "$MANIFEST_PATH" "$VERSION" "$DOWNLOAD_URL" "$ZIP_SIZE" "$PUB_DATE" "$PRERELEASE" "$MIN_SYSTEM_VERSION" "$SIGNATURE" <<'PY'
from __future__ import annotations

import json
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
version = sys.argv[2]
download_url = sys.argv[3]
length = int(sys.argv[4])
pub_date = sys.argv[5]
prerelease = sys.argv[6] == "1"
minimum_system_version = sys.argv[7]
signature = sys.argv[8]

entries = json.loads(manifest_path.read_text(encoding="utf-8"))
if not isinstance(entries, list):
    entries = []

entry = {
    "version": version,
    "downloadURL": download_url,
    "length": length,
    "pubDate": pub_date,
    "prerelease": prerelease,
    "minimumSystemVersion": minimum_system_version,
}
if signature:
    entry["signature"] = signature

updated = False
for idx, existing in enumerate(entries):
    if isinstance(existing, dict) and str(existing.get("version", "")).strip() == version:
        entries[idx] = entry
        updated = True
        break

if not updated:
    entries.append(entry)

manifest_path.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")
PY

"$SCRIPT_DIR/generate-appcast.sh" \
  --releases-json "$MANIFEST_PATH" \
  --output "$REPO_DIR/appcast.xml" \
  --title "$TITLE"

pushd "$REPO_DIR" >/dev/null
git add "appcast.xml" "releases.json" "archives/$ZIP_FILENAME"

if git diff --cached --quiet; then
  echo "==> No appcast changes to publish"
  exit 0
fi

git commit -m "chore(release): publish appcast for v$VERSION"

if [[ "$NO_PUSH" -eq 0 ]]; then
  git push origin "$BRANCH"
  echo "==> Appcast published to $APPCAST_REPO ($BRANCH)"
else
  echo "==> Appcast committed locally (push skipped): $REPO_DIR"
fi
popd >/dev/null
