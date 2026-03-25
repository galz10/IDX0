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

run_swift_checks() {
  require_cmd swiftformat
  require_cmd swiftlint
  run_step "SwiftFormat lint" swiftformat --lint --config .swiftformat idx0 idx0Tests Sources
  run_step "SwiftLint" swiftlint --config .swiftlint.yml
}

run_markdown_lint() {
  require_cmd markdownlint
  run_step "Markdown lint" markdownlint --config .markdownlint.json README.md docs .github
}

run_link_check() {
  require_cmd lychee

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
    run_swift_checks
    run_markdown_lint
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
