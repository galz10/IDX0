# Operations Playbook

Use this playbook for local validation, release readiness, and troubleshooting contributor environments.

## 1. Daily Developer Loop

```bash
./scripts/setup.sh
xcodegen generate
xcodebuild -project idx0.xcodeproj -scheme idx0 -destination 'platform=macOS' test
./scripts/maintainability-gate.sh
```

Optional core coverage gate:

```bash
./scripts/coverage-core.sh
```

## 2. Quality Gates

### Maintainability Gate

Command:

```bash
./scripts/maintainability-gate.sh
```

Checks:

- file size warnings/failures
- heuristic function size warnings/failures
- exception list from `docs/maintainability-exceptions.txt`

Current audit result (2026-03-22):

- `fails=0`
- `warnings=33`
- One explicit large-file exception: `idx0/Apps/VSCode/VSCodeRuntime.swift`

### Core Coverage Gate

Command:

```bash
./scripts/coverage-core.sh
```

Scope:

- `idx0/Services/**`
- `idx0/Models/**`
- `idx0/Persistence/**`
- `idx0/Utilities/**`

Default threshold: `90%`

## 3. Known Build/Test Environment Issues

### A. GhosttyKit not found

Symptom:

- missing `GhosttyKit.xcframework` or unresolved lib symbols

Fix:

```bash
./scripts/setup.sh
xcodegen generate
```

### B. Metal toolchain missing

Symptom:

- `cannot execute tool 'metal'`

Fix:

```bash
xcodebuild -downloadComponent MetalToolchain
```

### C. Coverage run fails during codesign

Observed on 2026-03-22:

- `Command CodeSign failed with a nonzero exit code`
- `errSecInternalComponent`

Impact:

- `./scripts/coverage-core.sh` exits before coverage summary

Mitigation:

- Run maintainability gate and standard tests.
- Re-run coverage on machine/profile with valid local signing context.
- Record the failure and log excerpt in PR verification notes.

## 4. Release/Pre-Merge Checklist

- [ ] Build and test pass on target macOS dev environment.
- [ ] Maintainability gate reviewed.
- [ ] Coverage gate attempted (or blocked reason documented).
- [ ] IPC and CLI behavior verified for contract changes.
- [ ] Migration behavior verified for schema changes.
- [ ] Manual smoke test:
  - create/focus/close sessions
  - run command palette actions
  - verify queue/checkpoint surfaces
  - verify terminal launch/fallback behavior

## 5. Incident Triage Pointers

### Logging

`Logger` uses subsystem `com.gal.idx0`.

Stream logs:

```bash
log stream --predicate 'subsystem == "com.gal.idx0"'
```

### IPC socket diagnostics

Default socket path:

- `~/Library/Application Support/idx0/run/idx0.sock`

Check socket exists:

```bash
ls -la ~/Library/Application\ Support/idx0/run
```

### Runtime data directories

- session/workflow state: `~/Library/Application Support/idx0/`
- VSCode runtime data: `~/Library/Application Support/idx0/openvscode/`
- T3 runtime data: `~/Library/Application Support/idx0/t3code/`
- OpenCode runtime data: `~/Library/Application Support/idx0/opencode/`

## 6. Escalation Notes

If a regression touches launch/runtime/ghostty layers:

1. Capture exact reproduction steps and logs.
2. Identify whether behavior is in:
   - launch wrapper generation
   - terminal surface lifecycle
   - session/workflow orchestration
3. Add regression tests if fix is deterministic.
4. Document residual risk in PR summary.
