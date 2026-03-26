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
RUN_SETUP=1
RUN_PROJECT_GEN=1
RUN_TESTS=1
RUN_MAINTAINABILITY=1
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
DMG_SIGNING_IDENTITY="${DMG_SIGNING_IDENTITY:-}"
RUN_DMG_SMOKE_TEST=1

OUTPUT_DIR="$ROOT_DIR/dist"
DERIVED_DATA_PATH="$ROOT_DIR/.build/derived-release"

usage() {
  cat <<'EOF'
Build and package a manual macOS release for idx0.

Usage:
  ./scripts/manual-release.sh [options]

Options:
  --version <semver>          Release version. Defaults to MARKETING_VERSION from project.yml.
  --output-dir <dir>          Directory for final artifacts. Default: ./dist
  --derived-data <dir>        Xcode DerivedData path for release build. Default: ./.build/derived-release
  --skip-setup                Skip ./scripts/setup.sh
  --skip-project-gen          Skip xcodegen generate
  --skip-tests                Skip xcodebuild test gate
  --skip-maintainability      Skip ./scripts/maintainability-gate.sh
  --skip-dmg-smoke-test       Skip post-notarization DMG smoke test
  --notary-profile <name>     Keychain profile for notarytool (required; can also use NOTARY_PROFILE)
  --dmg-sign-identity <name>  Signing identity for DMG codesign (required; can also use DMG_SIGNING_IDENTITY)
  -h, --help                  Show this help text
EOF
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
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --derived-data)
      DERIVED_DATA_PATH="${2:-}"
      shift 2
      ;;
    --skip-setup)
      RUN_SETUP=0
      shift
      ;;
    --skip-project-gen)
      RUN_PROJECT_GEN=0
      shift
      ;;
    --skip-tests)
      RUN_TESTS=0
      shift
      ;;
    --skip-maintainability)
      RUN_MAINTAINABILITY=0
      shift
      ;;
    --skip-dmg-smoke-test)
      RUN_DMG_SMOKE_TEST=0
      shift
      ;;
    --notary-profile)
      NOTARY_PROFILE="${2:-}"
      shift 2
      ;;
    --dmg-sign-identity)
      DMG_SIGNING_IDENTITY="${2:-}"
      shift 2
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

if [[ -z "$VERSION" ]]; then
  echo "error: version is empty" >&2
  exit 1
fi

if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "error: no notary profile provided." >&2
  echo "hint: pass --notary-profile <name> or export NOTARY_PROFILE=<name>" >&2
  exit 1
fi

if [[ -z "$DMG_SIGNING_IDENTITY" ]]; then
  echo "error: no DMG signing identity provided." >&2
  echo "hint: pass --dmg-sign-identity <name> or export DMG_SIGNING_IDENTITY=<name>" >&2
  exit 1
fi

require_cmd xcodebuild
require_cmd xcodegen
require_cmd ditto
require_cmd tar
require_cmd hdiutil
require_cmd shasum
require_cmd codesign
require_cmd spctl
require_cmd xcrun

echo "==> Manual release configuration"
echo "Version: $VERSION"
echo "Output directory: $OUTPUT_DIR"
echo "DerivedData: $DERIVED_DATA_PATH"
echo "Run setup: $RUN_SETUP"
echo "Run project generation: $RUN_PROJECT_GEN"
echo "Run tests: $RUN_TESTS"
echo "Run maintainability gate: $RUN_MAINTAINABILITY"
echo "Notarize: 1"
echo "Notary profile: $NOTARY_PROFILE"
echo "DMG signing identity: $DMG_SIGNING_IDENTITY"
echo "Run DMG smoke test: $RUN_DMG_SMOKE_TEST"
echo

mkdir -p "$OUTPUT_DIR"
mkdir -p "$ROOT_DIR/.build"

if [[ "$RUN_SETUP" -eq 1 ]]; then
  echo "==> Running setup"
  ./scripts/setup.sh
fi

if [[ "$RUN_PROJECT_GEN" -eq 1 ]]; then
  echo "==> Generating Xcode project"
  xcodegen generate
fi

if [[ "$RUN_TESTS" -eq 1 ]]; then
  echo "==> Running test gate"
  xcodebuild -project idx0.xcodeproj -scheme idx0 -destination 'platform=macOS' test
fi

if [[ "$RUN_MAINTAINABILITY" -eq 1 ]]; then
  echo "==> Running maintainability gate"
  ./scripts/maintainability-gate.sh
fi

echo "==> Building Release app"
xcodebuild \
  -project idx0.xcodeproj \
  -scheme idx0 \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  clean build

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/idx0.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: built app not found at $APP_PATH" >&2
  exit 1
fi

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Gatekeeper assessment (informational pre-notarization check)"
if spctl --assess --type execute --verbose "$APP_PATH"; then
  echo "==> Gatekeeper accepted app bundle"
else
  echo "warning: Gatekeeper rejected the app bundle before notarization."
  echo "warning: This is expected for non-notarized builds or Apple Development signatures."
  echo "warning: Continuing packaging flow."
fi

ZIP_PATH="$OUTPUT_DIR/IDX0-${VERSION}-mac.zip"
TAR_PATH="$OUTPUT_DIR/IDX0-${VERSION}-mac.tar.gz"
DMG_PATH="$OUTPUT_DIR/IDX0-${VERSION}.dmg"
CHECKSUM_PATH="$OUTPUT_DIR/SHA256SUMS.txt"

echo "==> Packaging zip"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Packaging tar.gz"
rm -f "$TAR_PATH"
tar -czf "$TAR_PATH" -C "$(dirname "$APP_PATH")" "$(basename "$APP_PATH")"

echo "==> Packaging dmg"
DMG_STAGE_DIR="$(mktemp -d "$ROOT_DIR/.build/dmg-stage.XXXXXX")"
DMG_MOUNT_POINT=""
DMG_DEVICE=""
cleanup() {
  local mount_point="${DMG_MOUNT_POINT:-}"
  if [[ -n "${DMG_DEVICE:-}" ]]; then
    hdiutil detach "$DMG_DEVICE" >/dev/null 2>&1 || true
    DMG_DEVICE=""
  elif [[ -n "$mount_point" ]]; then
    hdiutil detach "$mount_point" >/dev/null 2>&1 || true
  fi
  if [[ -n "$mount_point" ]]; then
    rm -rf "$mount_point"
  fi
  DMG_MOUNT_POINT=""
  rm -rf "$DMG_STAGE_DIR"
}
trap cleanup EXIT

cp -R "$APP_PATH" "$DMG_STAGE_DIR/"
ln -s /Applications "$DMG_STAGE_DIR/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "IDX0" -srcfolder "$DMG_STAGE_DIR" -ov -format UDZO "$DMG_PATH"

echo "==> Signing dmg"
codesign --force --sign "$DMG_SIGNING_IDENTITY" --timestamp "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

echo "==> Notarizing zip"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Notarizing dmg"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling dmg"
xcrun stapler staple "$DMG_PATH"

if [[ "$RUN_DMG_SMOKE_TEST" -eq 1 ]]; then
  echo "==> Running dmg smoke test"
  DMG_MOUNT_POINT="$(mktemp -d "$ROOT_DIR/.build/dmg-mount.XXXXXX")"
  ATTACH_OUTPUT="$(hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$DMG_MOUNT_POINT")"
  DMG_DEVICE="$(echo "$ATTACH_OUTPUT" | awk '/^\/dev\// {print $1; exit}')"

  MOUNTED_APP_PATH="$DMG_MOUNT_POINT/idx0.app"
  if [[ ! -d "$MOUNTED_APP_PATH" ]]; then
    echo "error: smoke test failed; mounted DMG missing idx0.app at $MOUNTED_APP_PATH" >&2
    exit 1
  fi

  if [[ ! -L "$DMG_MOUNT_POINT/Applications" ]]; then
    echo "error: smoke test failed; mounted DMG missing /Applications symlink" >&2
    exit 1
  fi

  codesign --verify --deep --strict --verbose=2 "$MOUNTED_APP_PATH"
  spctl --assess --type execute --verbose "$MOUNTED_APP_PATH"

  if [[ -n "$DMG_DEVICE" ]]; then
    hdiutil detach "$DMG_DEVICE" >/dev/null
    DMG_DEVICE=""
  else
    hdiutil detach "$DMG_MOUNT_POINT" >/dev/null
  fi
  rm -rf "$DMG_MOUNT_POINT"
  DMG_MOUNT_POINT=""
fi

echo "==> Writing SHA256 checksums"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$(basename "$DMG_PATH")" "$(basename "$ZIP_PATH")" "$(basename "$TAR_PATH")" > "$(basename "$CHECKSUM_PATH")"
)

echo
echo "==> Release artifacts ready"
ls -lh "$DMG_PATH" "$ZIP_PATH" "$TAR_PATH" "$CHECKSUM_PATH"
