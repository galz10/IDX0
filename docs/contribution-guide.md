# Contribution Guide

This guide explains how to make safe, high-signal contributions to `idx0` with minimal regressions.

## 1. Working Principles

- Keep the app session-first: durable behavior should be session scoped, not tied to transient UI state.
- Preserve command-surface parity: if behavior changes, keyboard/menu/palette/IPC paths must stay aligned.
- Prefer incremental extraction over broad rewrites in one patch.
- Add tests with behavior changes, especially for service/domain logic.
- Keep terminal quality and launch reliability as release-blocking concerns.

## 2. Environment Setup

Prerequisites:

```bash
brew install zig xcodegen
xcodebuild -downloadComponent MetalToolchain
```

Project bootstrap:

```bash
./scripts/setup.sh
xcodegen generate
open idx0.xcodeproj
```

If `GhosttyKit.xcframework` is missing or stale, re-run `./scripts/setup.sh`.

## 3. Recommended Branch and Scope Strategy

- Prefer one cohesive concern per branch/PR.
- Keep architecture changes separate from new product behavior when possible.
- For repo-aware work, use worktrees for isolated testing contexts.

Suggested branch naming:

- `idx0/<area>-<intent>` (for example: `idx0/workflow-queue-filter-fix`)

## 4. Standard Contribution Flow

1. Read relevant docs:
   - Architecture: `docs/architecture/*`
   - Style: `docs/style-guide.md`
   - Testing: `docs/testing-guide.md`
2. Confirm ownership boundary:
   - UI only: `idx0/UI/**`
   - Session/platform logic: `idx0/Services/Session/**`
   - Workflow/inbox/review logic: `idx0/Services/Workflow/**`
   - IPC/CLI contract: `idx0/App/IPCCommandRouter.swift`, `Sources/IPCShared/IPCContract.swift`, `Sources/idx0/idx0.swift`
3. Implement in smallest viable slice.
4. Add/update tests in `idx0Tests/**`.
5. Run local gates:
  - `./scripts/install-hooks.sh` (one-time per clone)
  - `./scripts/presubmit.sh fast` for quick local iteration
  - `./scripts/presubmit.sh lint`
  - `./scripts/presubmit.sh docs`
  - `./scripts/presubmit.sh test` (or targeted suites during iteration)
6. Update docs for behavioral, architectural, or protocol changes.
7. Submit PR with risk notes and verification commands.

## 5. Change Playbooks

### A. Add a New User Command

Example: new action available in menu + shortcut + command palette + optional IPC.

1. Add action ID in `idx0/Keyboard/ShortcutActionID.swift`.
2. Add bindings in `idx0/Keyboard/ShortcutRegistry.swift`.
3. Route behavior in `idx0/App/AppCoordinator+ShortcutCommandDispatcher.swift`.
4. Ensure command registry parity in `idx0/App/Commands/AppCommandRegistry.swift` (usually automatic from shortcut registry).
5. Expose in UI where needed:
   - App menu in `idx0/App/idx0App.swift`
   - command palette in `idx0/UI/CommandPaletteOverlay.swift`
6. Add tests:
   - `idx0Tests/AppCommandRegistryTests.swift`
   - shortcut behavior tests in `idx0Tests/Keyboard/ShortcutRegistryTests.swift`

### B. Add or Change IPC/CLI Contract

1. Update shared contract constants in `Sources/IPCShared/IPCContract.swift`.
2. Add command handling in `idx0/App/IPCCommandRouter.swift`.
3. Add/adjust CLI wiring in `Sources/idx0/idx0.swift`.
4. Add tests (prefer integration-style IPC round-trip where practical).
5. Update `docs/ipc-protocol.md` in same PR.

### C. Add a New Niri App Tile Integration

1. Define descriptor and runtime behavior via `NiriAppDescriptor`.
2. Register in session bootstrap path (`SessionService` app registration logic).
3. Implement controller conforming to `NiriAppTileRuntimeControlling`.
4. Ensure generic paths work:
   - create/retry/stop/zoom
   - cleanup on tile close and session close
5. Add `SessionServiceTests+Niri.swift` coverage for:
   - create/focus/retry/cleanup invariants

### D. Add New Persisted State

1. Decide owner file/store (sessions/projects/inbox/workflow/layout/settings/tile-state).
2. Add defaulted decode path for backward compatibility.
3. Keep schema migration non-destructive.
4. Add round-trip and migration tests.
5. Document in `docs/architecture/persistence-and-state.md`.

## 6. High-Risk Areas (Review Carefully)

- `idx0/Services/Session/SessionService+RuntimeLaunch.swift`
- `idx0/Services/Session/SessionLauncher.swift`
- `idx0/Terminal/GhosttyAppHost.swift`
- `idx0/Terminal/GhosttyTerminalSurface.swift`
- `idx0/App/IPCCommandRouter.swift`
- `idx0/Services/Workflow/WorkflowService*.swift`

Changes here can affect app launch, terminal lifecycle, queue semantics, or command interoperability.

## 7. Definition of Done

A change is done when:

- Behavior is correct across all intended surfaces.
- Relevant tests are added/updated and passing.
- Maintainability gate is green (or warnings are consciously accepted with rationale).
- Docs are updated for any public/internal contract changes.
- No unrelated files were modified accidentally.

## 8. PR Checklist

- [ ] Problem and user impact clearly described.
- [ ] Scope is focused and reversible.
- [ ] Tests cover new behavior and regressions.
- [ ] `docs/` updated where behavior/contracts changed.
- [ ] `lint-docs` and `tests` checks are green.
- [ ] `maintainability` report has been reviewed.
- [ ] Commands used for verification listed in PR description.
- [ ] Risks/follow-ups explicitly noted.
