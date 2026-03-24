# Testing Guide

This guide defines how `idx0` tests are organized, how to add new tests, and which gates to run before merging.

## 1. Test Philosophy

- Protect behavior at service/domain boundaries first.
- Keep tests deterministic and filesystem-isolated.
- Prefer focused unit tests with lightweight stubs over broad end-to-end suites.
- Use integration tests selectively for IPC, git worktree lifecycle, and persistence reload behavior.

## 2. Suite Map

Main test target: `idx0Tests`

Key suites:

- Session domain:
  - `SessionServiceTests.swift`
  - `SessionServiceTests+Launch.swift`
  - `SessionServiceTests+Niri.swift`
  - `SessionServiceIntegrationTests.swift`
- Workflow domain:
  - `WorkflowServiceTests.swift`
  - `WorkflowModelsTests.swift`
  - `SupervisionQueueServiceTests.swift`
- Git/worktree/runtime utilities:
  - `GitServiceParsingTests.swift`
  - `WorktreePathGenerationTests.swift`
  - `AutoCheckpointServiceTests.swift`
  - `AgentOutputScannerTests.swift`
- Command/keyboard/settings:
  - `AppCommandRegistryTests.swift`
  - `Keyboard/ShortcutRegistryTests.swift`
  - `AppSettingsKeyboardTests.swift`
- Runtime integration packages:
  - `Apps/VSCode/VSCodeRuntimeTests.swift`
  - `Apps/T3Code/T3CodeRuntimeTests.swift`
  - `Apps/Excalidraw/ExcalidrawRuntimeTests.swift`

## 3. Naming and Structure Conventions

- Test name format: `test<BehaviorUnderCondition>()`
- Arrange/act/assert should be readable without helper indirection unless repeated heavily.
- Prefer one behavior assertion focus per test.
- Use extensions (as done for `SessionServiceTests`) to keep large domains grouped by concern.

## 4. Fixture and Stub Patterns

Patterns already used in repo:

- Temporary root directories per test to isolate persistence.
- Local fixture builders (`Fixture`, `makeService`) for domain wiring.
- Protocol-backed stubs for external effects (`ProcessRunnerProtocol`, `GitServiceProtocol`).
- Minimal test doubles for runtime tile controllers (see Niri app tracker stubs).

Recommended approach:

1. Define protocol seam in production code if none exists.
2. Build tiny in-test stub with explicit expectations.
3. Assert both outputs and important side effects.

## 5. What to Test for Common Change Types

### Service behavior change

- State mutation in service collections.
- Callback behavior.
- Persistence side effects when relevant.
- Attention/queue/session focus invariants.

### IPC command change

- Router request validation.
- Success and error response shape.
- CLI mapping where applicable.

### New setting

- Decode default behavior for missing field.
- Round-trip encode/decode.
- Behavioral effect in service/UI entry points.

### Runtime launch/sandbox change

- Manifest generation.
- Wrapper fallback behavior.
- Launch status reporting.
- Restrictions/degraded path behavior.

### Niri layout change

- Workspace invariants.
- Focus/camera updates.
- Tile controller lifecycle and cleanup.

## 6. Command Reference

Run full test suite:

```bash
xcodebuild -project idx0.xcodeproj -scheme idx0 -destination 'platform=macOS' test
```

Maintainability gate:

```bash
./scripts/maintainability-gate.sh
```

Core coverage gate:

```bash
./scripts/coverage-core.sh
```

Coverage scope is limited to:

- `idx0/Services/**`
- `idx0/Models/**`
- `idx0/Persistence/**`
- `idx0/Utilities/**`

## 7. Recommended Local Verification Order

1. Targeted tests for touched areas.
2. `./scripts/maintainability-gate.sh`
3. Full `xcodebuild ... test`
4. `./scripts/coverage-core.sh` (when environment supports full code-sign/test run)

## 8. Known Environment Caveat (2026-03-22)

Observed during docs audit:

- `./scripts/coverage-core.sh` can fail on some machines during framework code-sign with:
  - `errSecInternalComponent`
  - `Command CodeSign failed with a nonzero exit code`

When this occurs:

- Record the failure in PR validation notes.
- Still run targeted/full tests when possible.
- Re-run in a machine/profile with valid local signing context.

## 9. Pre-Merge Test Checklist

- [ ] Tests added/updated for new behavior.
- [ ] No obvious regression gaps in changed domain.
- [ ] Maintainability gate run and reviewed.
- [ ] Full test run attempted; failures triaged and explained.
- [ ] Coverage gate attempted for non-trivial core logic changes.
