# idx0 Documentation Hub

Last updated: 2026-03-25

This folder is the contributor handbook for `idx0`, a native macOS session-first terminal app built with SwiftUI + AppKit + libghostty.

## Start Here

- New contributors: read [Contribution Guide](contribution-guide.md), then [Style Guide](style-guide.md), then [Testing Guide](testing-guide.md).
- Feature or refactor work: read [Architecture Deep Dive](architecture/deep-dive.md) and [Runtime Integrations](architecture/runtime-integrations.md).
- Data/model changes: read [Persistence and State](architecture/persistence-and-state.md).
- Release hardening and incidents: use [Operations Playbook](operations-playbook.md).
- Publishing a version: follow [Release Runbook](release-runbook.md).

## Repository Snapshot (2026-03-22)

- Swift files in app/tests/package targets: `161`
- Approx Swift LOC: `35,907`
- Main app target: `idx0` (macOS 14+, Swift 6)
- Test target: `idx0Tests`
- External runtime dependency: `ghostty` submodule + `GhosttyKit.xcframework` symlinked into repo root

## Documentation Map

### Core Contributor Guides

- [Contribution Guide](contribution-guide.md)
- [Style Guide](style-guide.md)
- [Testing Guide](testing-guide.md)
- [Operations Playbook](operations-playbook.md)
- [Release Runbook](release-runbook.md)

### Architecture Guides

- [Architecture Deep Dive](architecture/deep-dive.md)
- [Runtime Integrations](architecture/runtime-integrations.md)
- [Persistence and State](architecture/persistence-and-state.md)

### Existing Reference Docs (kept and still valid)

- [Architecture Map and Ownership Notes](architecture-map.md)
- [Engineering Guidelines](engineering-guidelines.md)
- [IPC Protocol](ipc-protocol.md)
- [Niri Keybinding Compatibility](niri-keybinding-compatibility.md)
- [Core Coverage Policy](testing/coverage.md)

## Core Commands

From repo root:

```bash
# One-time setup (submodule + GhosttyKit build/link)
./scripts/setup.sh

# Regenerate project from project.yml
xcodegen generate

# Build tests and app
xcodebuild -project idx0.xcodeproj -scheme idx0 -destination 'platform=macOS' test

# Maintainability policy gate
./scripts/maintainability-gate.sh

# Core coverage gate
./scripts/coverage-core.sh
```

## Contributor Safety Notes

- Do not edit `ghostty/` casually. Treat it as an upstream dependency unless a change is explicitly intended.
- Keep command-surface parity intact: menu, shortcuts, command palette, and IPC should map to the same action model.
- Update docs in the same PR for architecture, workflow, schema, IPC, or command-surface changes.
