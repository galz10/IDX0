# Release Runbook

Use this guide when publishing a new IDX0 desktop release.

## 1. One-Time Prerequisites

1. Confirm Apple credentials for notarization are stored in a keychain profile:

```bash
xcrun notarytool store-credentials "<profile-name>" --apple-id "<apple-id>" --team-id "<team-id>" --password "<app-specific-password>"
```

2. Confirm your DMG signing identity exists:

```bash
security find-identity -v -p codesigning
```

3. Confirm GitHub CLI auth:

```bash
gh auth status
```

## 2. Per-Release Preflight

1. Choose version `X.Y.Z`.
2. Make sure this repo and `README.md` are clean (no unstaged/staged local edits).
3. If you want idx-web auto-update, make sure the target file is clean too.
4. From repo root, verify project checks:

```bash
./scripts/setup.sh
xcodegen generate
xcodebuild -project idx0.xcodeproj -scheme idx0 -destination 'platform=macOS' test
./scripts/maintainability-gate.sh
```

## 3. Build + Notarize Artifacts

Run:

```bash
./scripts/manual-release.sh \
  --version X.Y.Z \
  --notary-profile "<profile-name>" \
  --dmg-sign-identity "Developer ID Application: <name> (<team-id>)"
```

Default behavior:

- Runs setup/project generation/tests/maintainability gate.
- Builds release app.
- Packages `zip`, `tar.gz`, and `dmg`.
- Signs and notarizes artifacts.
- Staples DMG.
- Runs DMG smoke test.

Artifacts are written to `dist/`:

- `IDX0-X.Y.Z.dmg`
- `IDX0-X.Y.Z-mac.zip`
- `IDX0-X.Y.Z-mac.tar.gz`
- `SHA256SUMS.txt`

## 4. Publish GitHub Release + Update Download Links

Draft release (default):

```bash
./scripts/publish-github-release.sh --version X.Y.Z
```

Published release:

```bash
./scripts/publish-github-release.sh --version X.Y.Z --publish
```

Notes:

- `--version` is required.
- Download URL now follows the selected `--repo` (or current repo).
- Default idx-web path is `/Users/gal/Documents/Github/idx-web/index.html`.
- Override idx-web path with `--idx-web-index <path>`.
- Enforce idx-web update success with `--require-idx-web-update`.
- If idx-web update is not required and preflight fails, the script warns and skips idx-web automation.

## 5. Verify Release

1. Validate release assets:

```bash
gh release view vX.Y.Z --repo galz10/IDX0
```

2. Open release page and verify download links.
3. Confirm `README.md` download link points to `vX.Y.Z`.
4. If idx-web update was enabled, confirm CTA URL and `data-release-version`.

## 6. Recommended Command Template

```bash
VERSION="X.Y.Z"
NOTARY_PROFILE="<profile-name>"
DMG_SIGN_IDENTITY="Developer ID Application: <name> (<team-id>)"

./scripts/manual-release.sh \
  --version "$VERSION" \
  --notary-profile "$NOTARY_PROFILE" \
  --dmg-sign-identity "$DMG_SIGN_IDENTITY"

./scripts/publish-github-release.sh \
  --version "$VERSION" \
  --publish
```
