#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

usage() {
  cat <<'USAGE'
Run local quality gates for idx0.

Usage:
  ./scripts/presubmit.sh lint|docs|test|fast

Subcommands:
  lint  SwiftFormat lint + SwiftLint + maintainability gate
  docs  Markdown lint + link check
  test  Full xcodebuild test suite
  fast  SwiftFormat lint + SwiftLint + markdown lint (no full tests)
USAGE
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: required command not found: $cmd" >&2
    exit 1
  fi
}

run_step() {
  local label="$1"
  shift
  echo "==> $label"
  "$@"
}

run_swiftlint_for_changed_files() {
  local swift_files=("$@")
  local i
  local status=0

  export SCRIPT_INPUT_FILE_COUNT="${#swift_files[@]}"
  for i in "${!swift_files[@]}"; do
    export "SCRIPT_INPUT_FILE_$i=${swift_files[$i]}"
  done

  if ! run_step "SwiftLint (changed files)" swiftlint lint --config .swiftlint.yml --use-script-input-files; then
    status=$?
  fi

  for i in "${!swift_files[@]}"; do
    unset "SCRIPT_INPUT_FILE_$i"
  done
  unset SCRIPT_INPUT_FILE_COUNT

  return "$status"
}

run_swift_checks() {
  require_cmd swiftformat
  require_cmd swiftlint

  if [[ "${PRESUBMIT_SWIFT_CHANGED_ONLY:-0}" == "1" ]]; then
    require_cmd git

    local diff_range="${PRESUBMIT_DIFF_RANGE:-}"
    if [[ -z "$diff_range" ]]; then
      if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
        diff_range="HEAD~1...HEAD"
      else
        diff_range="HEAD"
      fi
    fi

    local -a swift_files=()
    while IFS= read -r -d '' file; do
      [[ -z "$file" ]] && continue
      case "$file" in
        idx0/*|idx0Tests/*|Sources/*)
          if [[ "$file" == -* ]]; then
            file="./$file"
          fi
          swift_files+=("$file")
          ;;
      esac
    done < <(git diff --name-only -z --diff-filter=ACMRTUXB "$diff_range" -- '*.swift')

    if [[ "${#swift_files[@]}" -eq 0 ]]; then
      echo "==> No changed Swift files in '$diff_range'; skipping SwiftFormat/SwiftLint"
      return
    fi

    run_step "SwiftFormat lint (changed files)" swiftformat --lint --config .swiftformat "${swift_files[@]}"
    run_swiftlint_for_changed_files "${swift_files[@]}"
    return
  fi

  run_step "SwiftFormat lint" swiftformat --lint --config .swiftformat idx0 idx0Tests Sources
  run_step "SwiftLint" swiftlint --config .swiftlint.yml
}

resolve_diff_range() {
  local diff_range="${PRESUBMIT_DIFF_RANGE:-}"
  if [[ -z "$diff_range" ]]; then
    if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
      diff_range="HEAD~1...HEAD"
    else
      diff_range="HEAD"
    fi
  fi

  printf '%s\n' "$diff_range"
}

collect_changed_markdown_files() {
  require_cmd git

  local diff_range
  diff_range="$(resolve_diff_range)"

  local -a md_files=()
  while IFS= read -r -d '' file; do
    [[ -z "$file" ]] && continue
    case "$file" in
      README.md|docs/*|.github/*)
        if [[ "$file" == -* ]]; then
          file="./$file"
        fi
        md_files+=("$file")
        ;;
    esac
  done < <(git diff --name-only -z --diff-filter=ACMRTUXB "$diff_range" -- '*.md')

  if [[ "${#md_files[@]}" -eq 0 ]]; then
    echo "==> No changed markdown files in '$diff_range'"
    return
  fi

  printf '%s\0' "${md_files[@]}"
}

run_markdown_lint() {
  require_cmd markdownlint

  if [[ "${PRESUBMIT_MD_CHANGED_ONLY:-0}" == "1" ]]; then
    local -a md_files=()
    while IFS= read -r -d '' file; do
      md_files+=("$file")
    done < <(collect_changed_markdown_files)

    if [[ "${#md_files[@]}" -eq 0 ]]; then
      return
    fi

    run_step "Markdown lint (changed files)" markdownlint --config .markdownlint.json "${md_files[@]}"
    return
  fi

  run_step "Markdown lint" markdownlint --config .markdownlint.json README.md docs .github
}

run_link_check() {
  require_cmd lychee

  if [[ "${PRESUBMIT_MD_CHANGED_ONLY:-0}" == "1" ]]; then
    local -a md_files=()
    while IFS= read -r -d '' file; do
      md_files+=("$file")
    done < <(collect_changed_markdown_files)

    if [[ "${#md_files[@]}" -eq 0 ]]; then
      return
    fi

    run_step "Lychee link check (changed files)" lychee --config .lychee.toml "${md_files[@]}"
    return
  fi

  local md_files=()
  while IFS= read -r -d '' file; do
    md_files+=("$file")
  done < <(find README.md docs .github -type f -name '*.md' -print0)

  if [[ "${#md_files[@]}" -eq 0 ]]; then
    echo "error: no markdown files found for link checking" >&2
    exit 1
  fi

  run_step "Lychee link check" lychee --config .lychee.toml "${md_files[@]}"
}

run_tests() {
  run_step "xcodebuild tests" xcodebuild -project idx0.xcodeproj -scheme idx0 -destination 'platform=macOS' test
}

run_maintainability() {
  if [[ "${PRESUBMIT_RUN_MAINTAINABILITY:-1}" == "1" ]]; then
    run_step "Maintainability gate" ./scripts/maintainability-gate.sh
  else
    echo "==> Skipping maintainability gate (PRESUBMIT_RUN_MAINTAINABILITY=0)"
  fi
}

COMMAND="${1:-}"

case "$COMMAND" in
  lint)
    run_swift_checks
    run_maintainability
    ;;
  docs)
    run_markdown_lint
    run_link_check
    ;;
  test)
    run_tests
    ;;
  fast)
    PRESUBMIT_SWIFT_CHANGED_ONLY="${PRESUBMIT_SWIFT_CHANGED_ONLY:-1}" run_swift_checks
    PRESUBMIT_MD_CHANGED_ONLY="${PRESUBMIT_MD_CHANGED_ONLY:-1}" run_markdown_lint
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 1
    ;;
esac

echo "==> Presubmit '$COMMAND' completed successfully"
