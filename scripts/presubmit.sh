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

normalize_failed_test_name() {
  local value="$1"
  local trimmed inside class_part method_part class_name

  trimmed="${value#"${value%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  trimmed="${trimmed%\(\)}"
  if [[ -z "$trimmed" ]]; then
    return
  fi

  if [[ "$trimmed" == "-["*"]"* ]]; then
    inside="${trimmed#*-[}"
    inside="${inside%%]*}"
    class_part="${inside%% *}"
    method_part="${inside#* }"
    class_name="${class_part##*.}"
    if [[ -n "$class_name" && -n "$method_part" && "$method_part" != "$inside" ]]; then
      echo "${class_name}.${method_part}"
      return
    fi
  fi

  # Convert module-qualified names (Module.Class.testName) into Class.testName.
  if [[ "$trimmed" == *.*.* ]]; then
    trimmed="${trimmed#*.}"
  fi

  echo "$trimmed"
}

extract_failed_tests() {
  local log_file="$1"
  local line in_failing_block normalized

  in_failing_block=0
  while IFS= read -r line; do
    if [[ "$line" == "Failing tests:"* ]]; then
      in_failing_block=1
      continue
    fi

    if [[ "$in_failing_block" -eq 1 ]]; then
      if [[ -z "${line//[[:space:]]/}" ]]; then
        in_failing_block=0
        continue
      fi

      normalized="$(normalize_failed_test_name "$line")"
      [[ -n "$normalized" ]] && echo "$normalized"
      continue
    fi

    if [[ "$line" == *"Test Case "*"' failed"* ]]; then
      normalized="$(normalize_failed_test_name "$line")"
      [[ -n "$normalized" ]] && echo "$normalized"
    fi
  done < "$log_file" | awk '!seen[$0]++'
}

extract_xcresult_path() {
  local log_file="$1"
  local line next_is_path

  next_is_path=0
  while IFS= read -r line; do
    if [[ "$next_is_path" -eq 1 ]]; then
      line="${line#"${line%%[![:space:]]*}"}"
      [[ -n "$line" ]] && echo "$line"
      return
    fi

    if [[ "$line" == "Test session results, code coverage, and logs:"* ]]; then
      next_is_path=1
    fi
  done < "$log_file"
}

lookup_failure_reason_for_test() {
  local log_file="$1"
  local test_name="$2"
  local class_name method_name reason_line failed_line_number start_line reason

  class_name="${test_name%%.*}"
  method_name="${test_name#*.}"
  method_name="${method_name%\(\)}"

  reason_line="$(
    grep -F ".${class_name} ${method_name}]" "$log_file" 2>/dev/null \
      | grep "error:" 2>/dev/null \
      | head -n 1 \
      || true
  )"

  if [[ -z "$reason_line" ]]; then
    reason_line="$(
      grep -F "${class_name}.${method_name}" "$log_file" 2>/dev/null \
        | grep "error:" 2>/dev/null \
        | head -n 1 \
        || true
    )"
  fi

  if [[ -z "$reason_line" ]]; then
    failed_line_number="$(
      grep -nF ".${class_name} ${method_name}]' failed" "$log_file" 2>/dev/null \
        | head -n 1 \
        | cut -d: -f1 \
        || true
    )"

    if [[ -n "$failed_line_number" ]]; then
      start_line=$((failed_line_number > 25 ? failed_line_number - 25 : 1))
      reason_line="$(
        sed -n "${start_line},${failed_line_number}p" "$log_file" \
          | grep -E "error:|Assertion failed:|fatal error:|XCTAssert" 2>/dev/null \
          | tail -n 1 \
          || true
      )"
    fi
  fi

  if [[ -z "$reason_line" ]]; then
    echo "No explicit assertion/error line found in xcodebuild output."
    return
  fi

  reason="$(printf '%s' "$reason_line" | sed -E 's/^[[:space:]]+//')"
  reason="$(printf '%s' "$reason" | sed -E 's#^.*error:[[:space:]]*-\[[^]]+\][[:space:]]*:[[:space:]]*##')"
  if [[ -z "$reason" ]]; then
    reason="$(printf '%s' "$reason_line" | sed -E 's/^[[:space:]]+//')"
  fi

  echo "$reason"
}

summarize_xcode_test_failures() {
  local log_file="$1"
  local -a failed_tests=()
  local test_name reason index xcresult_path

  while IFS= read -r test_name; do
    [[ -z "$test_name" ]] && continue
    failed_tests+=("$test_name")
  done < <(extract_failed_tests "$log_file")

  xcresult_path="$(extract_xcresult_path "$log_file")"

  echo
  echo "==> Test failure summary"

  if [[ "${#failed_tests[@]}" -eq 0 ]]; then
    echo "No individual failing XCTest cases were parsed."
    echo "Top error lines:"
    grep -E "error:|\\*\\* TEST FAILED \\*\\*|BUILD FAILED" "$log_file" 2>/dev/null \
      | head -n 12 \
      | sed 's/^/  - /' \
      || true
  else
    index=1
    for test_name in "${failed_tests[@]}"; do
      reason="$(lookup_failure_reason_for_test "$log_file" "$test_name")"
      echo "  $index. $test_name"
      echo "     reason: $reason"
      index=$((index + 1))
    done
  fi

  if [[ -n "$xcresult_path" ]]; then
    echo "xcresult: $xcresult_path"
  fi
}

run_tests() {
  local log_file

  log_file="$(mktemp -t idx0-presubmit-tests)"
  echo "==> xcodebuild tests"

  if xcodebuild -project idx0.xcodeproj -scheme idx0 -destination 'platform=macOS' test 2>&1 | tee "$log_file"; then
    rm -f "$log_file"
    return
  fi

  summarize_xcode_test_failures "$log_file"
  echo "==> Full xcodebuild log: $log_file"
  return 1
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
