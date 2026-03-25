#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

HOOKS_DIR="$ROOT_DIR/.githooks"
PRE_COMMIT_HOOK="$HOOKS_DIR/pre-commit"

if [[ ! -d "$HOOKS_DIR" ]]; then
  echo "error: hooks directory not found: $HOOKS_DIR" >&2
  exit 1
fi

if [[ ! -f "$PRE_COMMIT_HOOK" ]]; then
  echo "error: pre-commit hook not found: $PRE_COMMIT_HOOK" >&2
  exit 1
fi

chmod +x "$PRE_COMMIT_HOOK"
git config core.hooksPath .githooks

echo "==> Installed repo hooks"
echo "==> core.hooksPath set to .githooks"
