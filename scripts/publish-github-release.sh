#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

DEFAULT_VERSION="$(awk '/MARKETING_VERSION:/ {print $2; exit}' project.yml 2>/dev/null || true)"
if [[ -z "${DEFAULT_VERSION:-}" ]]; then
  DEFAULT_VERSION="0.0.1"
fi

VERSION=""
VERSION_WAS_SET=0
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
IDX_WEB_INDEX_DEFAULT_PATH="/Users/gal/Documents/Github/idx-web/index.html"
IDX_WEB_INDEX_PATH="${IDX_WEB_INDEX_PATH:-$IDX_WEB_INDEX_DEFAULT_PATH}"
REQUIRE_IDX_WEB_UPDATE=0
README_PATH="$ROOT_DIR/README.md"

COMMITTED_REPOS=()
PUSHED_REPOS=()
SKIPPED_REPOS=()
WARNED_REPOS=()

usage() {
  cat <<'EOF'
Create or update a GitHub release and upload dist artifacts.

Usage:
  ./scripts/publish-github-release.sh [options]

Options:
  --version <semver>          Release version (required).
  --dist-dir <dir>            Artifact directory. Default: ./dist
  --repo <owner/name>         GitHub repo (falls back to current gh repo context)
  --title <text>              Release title. Default: "IDX0 v<version>"
  --target <ref>              Git ref/sha used if a new tag is created (default: current HEAD)
  --notes-file <path>         Markdown notes file to use for release body
  --no-generate-notes         Disable --generate-notes when creating a new release
  --publish                   Create release as published (not draft)
  --prerelease                Mark release as prerelease
  --no-push-tag               Do not push tag to origin
  --idx-web-index <path>      Override idx-web download target (default: /Users/gal/Documents/Github/idx-web/index.html)
  --require-idx-web-update    Fail if idx-web update cannot run
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
      VERSION_WAS_SET=1
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
    --idx-web-index)
      IDX_WEB_INDEX_PATH="${2:-}"
      shift 2
      ;;
    --require-idx-web-update)
      REQUIRE_IDX_WEB_UPDATE=1
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

if [[ "$VERSION_WAS_SET" -ne 1 ]]; then
  echo "error: --version is required." >&2
  exit 1
fi

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
require_cmd perl

release_download_url() {
  local repo="$1"
  local tag="$2"
  local dmg_name="$3"
  echo "https://github.com/${repo}/releases/download/${tag}/${dmg_name}"
}

patch_idx_web_download_link() {
  local file="$1"
  local version="$2"
  local download_url="$3"

  if [[ ! -f "$file" ]]; then
    echo "error: idx-web download target not found: $file" >&2
    exit 1
  fi

  perl -0pi -e "s~https://github\\.com/[^/]+/[^/]+/releases/download/v[^\"']+/IDX0-[^\"']*\\.dmg~${download_url}~g" "$file"
  perl -0pi -e "s~(data-release-version=\")[^\"]*(\")~\${1}${version}\${2}~g" "$file"
}

patch_readme_download_link() {
  local file="$1"
  local download_url="$2"

  if [[ ! -f "$file" ]]; then
    echo "error: README not found at $file" >&2
    exit 1
  fi

  perl -0pi -e "s~https://github\\.com/[^/]+/[^/]+/releases/(?:tag/v[0-9A-Za-z._-]+|download/v[0-9A-Za-z._-]+/IDX0-[0-9A-Za-z._-]+(?:-arm)?\\.dmg)~${download_url}~g" "$file"
}

hash_file() {
  local file="$1"
  shasum -a 256 "$file" | awk '{print $1}'
}

record_skip() {
  local message="$1"
  SKIPPED_REPOS+=("$message")
}

record_warning() {
  local message="$1"
  WARNED_REPOS+=("$message")
}

preflight_patch_target() {
  local repo_hint="$1"
  local target_file="$2"
  local repo_label="$3"
  local required="${4:-1}"

  if [[ -z "$target_file" ]]; then
    if [[ "$required" -eq 1 ]]; then
      echo "error: $repo_label target path is empty." >&2
      exit 1
    fi
    record_warning "$repo_label: target path is empty, skipped"
    return 1
  fi

  if [[ ! -f "$target_file" ]]; then
    if [[ "$required" -eq 1 ]]; then
      echo "error: $repo_label target file not found: $target_file" >&2
      exit 1
    fi
    record_warning "$repo_label: target file not found ($target_file), skipped"
    return 1
  fi

  if [[ ! -d "$repo_hint" ]]; then
    if [[ "$required" -eq 1 ]]; then
      echo "error: repo path not found: $repo_hint" >&2
      exit 1
    fi
    record_warning "$repo_label: repo path not found ($repo_hint), skipped"
    return 1
  fi

  if ! git -C "$repo_hint" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [[ "$required" -eq 1 ]]; then
      echo "error: not a git repo: $repo_hint" >&2
      exit 1
    fi
    record_warning "$repo_label: not a git repo ($repo_hint), skipped"
    return 1
  fi

  local repo_root
  repo_root="$(git -C "$repo_hint" rev-parse --show-toplevel)"
  local rel_path="${target_file#$repo_root/}"
  if [[ "$rel_path" == "$target_file" ]]; then
    if [[ "$required" -eq 1 ]]; then
      echo "error: file is outside git repo ($repo_label): $target_file" >&2
      exit 1
    fi
    record_warning "$repo_label: file is outside git repo ($target_file), skipped"
    return 1
  fi

  if [[ -n "$(git -C "$repo_root" status --porcelain -- "$rel_path")" ]]; then
    if [[ "$required" -eq 1 ]]; then
      echo "error: pre-existing local changes detected in $repo_label ($rel_path)." >&2
      echo "hint: commit or stash file changes before running release automation." >&2
      exit 1
    fi
    record_warning "$repo_label: pre-existing local changes in $rel_path, skipped"
    return 1
  fi

  return 0
}

auto_commit_and_push_file() {
  local repo_hint="$1"
  local target_file="$2"
  local repo_label="$3"
  local optional_repo="${4:-0}"
  local commit_message="$5"

  if [[ ! -d "$repo_hint" ]]; then
    if [[ "$optional_repo" -eq 1 ]]; then
      record_warning "$repo_label: repo path not found ($repo_hint)"
      return 0
    fi
    echo "error: repo path not found: $repo_hint" >&2
    exit 1
  fi

  if ! git -C "$repo_hint" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [[ "$optional_repo" -eq 1 ]]; then
      record_warning "$repo_label: not a git repo, skipped git automation"
      return 0
    fi
    echo "error: not a git repo: $repo_hint" >&2
    exit 1
  fi

  local repo_root
  repo_root="$(git -C "$repo_hint" rev-parse --show-toplevel)"

  if [[ ! -f "$target_file" ]]; then
    record_skip "$repo_label: target file missing ($target_file)"
    return 0
  fi

  local rel_path="${target_file#$repo_root/}"
  if [[ "$rel_path" == "$target_file" ]]; then
    echo "error: file is outside git repo ($repo_label): $target_file" >&2
    exit 1
  fi

  if [[ -z "$(git -C "$repo_root" status --porcelain -- "$rel_path")" ]]; then
    record_skip "$repo_label: no changes in $rel_path"
    return 0
  fi

  git -C "$repo_root" add -- "$rel_path"
  if git -C "$repo_root" diff --cached --quiet -- "$rel_path"; then
    record_skip "$repo_label: no staged changes in $rel_path"
    return 0
  fi

  git -C "$repo_root" commit -m "$commit_message" -- "$rel_path"
  COMMITTED_REPOS+=("$repo_label")

  local current_branch
  current_branch="$(git -C "$repo_root" branch --show-current)"
  if [[ -z "$current_branch" ]]; then
    record_warning "$repo_label: detached HEAD, skipped push"
    return 0
  fi

  if git -C "$repo_root" rev-parse --abbrev-ref --symbolic-full-name "@{upstream}" >/dev/null 2>&1; then
    if git -C "$repo_root" push; then
      PUSHED_REPOS+=("$repo_label")
    else
      record_warning "$repo_label: push failed, commit left locally"
    fi
    return 0
  fi

  if git -C "$repo_root" push -u origin "$current_branch"; then
    PUSHED_REPOS+=("$repo_label")
  else
    record_warning "$repo_label: push -u origin $current_branch failed, commit left locally"
  fi
}

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

DOWNLOAD_URL="$(release_download_url "$REPO" "$TAG" "$(basename "$DMG_PATH")")"

preflight_patch_target "$ROOT_DIR" "$README_PATH" "IDX0" 1

IDX_WEB_CAN_UPDATE=1
if ! preflight_patch_target "$(dirname "$IDX_WEB_INDEX_PATH")" "$IDX_WEB_INDEX_PATH" "idx-web" "$REQUIRE_IDX_WEB_UPDATE"; then
  IDX_WEB_CAN_UPDATE=0
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

README_BEFORE_HASH="$(hash_file "$README_PATH")"
patch_readme_download_link "$README_PATH" "$DOWNLOAD_URL"
README_AFTER_HASH="$(hash_file "$README_PATH")"
README_CHANGED=0
if [[ "$README_BEFORE_HASH" != "$README_AFTER_HASH" ]]; then
  README_CHANGED=1
fi

IDX_WEB_CHANGED=0
if [[ "$IDX_WEB_CAN_UPDATE" -eq 1 ]]; then
  IDX_WEB_BEFORE_HASH="$(hash_file "$IDX_WEB_INDEX_PATH")"
  patch_idx_web_download_link "$IDX_WEB_INDEX_PATH" "$VERSION" "$DOWNLOAD_URL"
  IDX_WEB_AFTER_HASH="$(hash_file "$IDX_WEB_INDEX_PATH")"
  if [[ "$IDX_WEB_BEFORE_HASH" != "$IDX_WEB_AFTER_HASH" ]]; then
    IDX_WEB_CHANGED=1
  fi
fi

if [[ "$README_CHANGED" -eq 1 ]]; then
  auto_commit_and_push_file "$ROOT_DIR" "$README_PATH" "IDX0" 0 "chore(release): update README download link for $TAG"
else
  record_skip "IDX0: README already points at $DOWNLOAD_URL"
fi

if [[ "$IDX_WEB_CAN_UPDATE" -eq 1 && "$IDX_WEB_CHANGED" -eq 1 ]]; then
  auto_commit_and_push_file "$(dirname "$IDX_WEB_INDEX_PATH")" "$IDX_WEB_INDEX_PATH" "idx-web" 1 "chore(release): update download CTA for $TAG"
elif [[ "$IDX_WEB_CAN_UPDATE" -eq 1 ]]; then
  record_skip "idx-web: Download CTA already points at $DOWNLOAD_URL"
fi

echo
echo "==> Release ready"
echo "Repo: $REPO"
echo "Tag: $TAG"
echo "Download URL: $DOWNLOAD_URL"
echo "Assets:"
printf ' - %s\n' "$DMG_PATH" "$ZIP_PATH" "$TAR_PATH" "$CHECKSUM_PATH"

echo
echo "==> Git automation summary"
if [[ "${#COMMITTED_REPOS[@]}" -gt 0 ]]; then
  printf 'Committed:\n'
  printf ' - %s\n' "${COMMITTED_REPOS[@]}"
else
  echo "Committed: none"
fi

if [[ "${#PUSHED_REPOS[@]}" -gt 0 ]]; then
  printf 'Pushed:\n'
  printf ' - %s\n' "${PUSHED_REPOS[@]}"
else
  echo "Pushed: none"
fi

if [[ "${#SKIPPED_REPOS[@]}" -gt 0 ]]; then
  printf 'Skipped:\n'
  printf ' - %s\n' "${SKIPPED_REPOS[@]}"
fi

if [[ "${#WARNED_REPOS[@]}" -gt 0 ]]; then
  printf 'Warnings:\n'
  printf ' - %s\n' "${WARNED_REPOS[@]}"
fi

if [[ "$OPEN_WEB" -eq 1 ]]; then
  gh release view "$TAG" --repo "$REPO" --web
fi
