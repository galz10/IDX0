# Architecture Deep Dive

This document explains the current architecture of `idx0` in enough detail to modify major behavior safely.

## 1. Product-Level Shape

`idx0` is a native macOS app that combines:

- terminal runtime hosting (Ghostty bridge)
- session lifecycle management
- workflow supervision (queue/timeline/checkpoints/reviews/handoffs/approvals)
- keyboard/menu/palette/IPC command surfaces
- optional embedded browser and app tiles (Niri canvas mode)

## 2. Module Topology

Core directories:

- `idx0/App`: app bootstrap, command routing, IPC server/router
- `idx0/Services`: domain and integration logic
- `idx0/Models`: value models and persisted contracts
- `idx0/Persistence`: file-backed stores
- `idx0/Terminal`: Ghostty host/surfaces/session controllers
- `idx0/UI`: SwiftUI views and overlays
- `idx0/Apps`: Niri app tile runtimes (`t3-code`, `vscode`, `excalidraw`, `opencode`)
- `idx0/Keyboard`: shortcut models, registry, dispatch, validation
- `Sources/IPCShared`: shared IPC contract constants/types
- `Sources/idx0`: CLI client for IPC control

## 3. Startup and Boot Sequence

Primary path:

1. `idx0App` creates `AppCoordinator`.
2. `AppCoordinator` resolves filesystem paths via `BootstrapCoordinator`.
3. Stores/services are initialized:
   - `SessionService`
   - `WorkflowService`
   - `AutoCheckpointService`
   - `TerminalMonitorService`
   - `GitMonitor`
   - `IPCServer`
4. Event/callback wiring is established:
   - Session lifecycle callbacks feed workflow timeline/queue updates.
   - Terminal monitor updates session agent activity + checkpoint behavior.
5. Local key monitor is installed for shortcut handling.

## 4. Command Surface Architecture

Single action model:

- Action IDs: `ShortcutActionID`
- Bindings: `ShortcutRegistry`
- Dispatch entry: `AppCoordinator.performCommand(_:)`

Surfaces that converge on same action IDs:

- App menu (`idx0App.swift`)
- Keyboard (`ShortcutDispatcher` + local event monitor)
- Command palette (`CommandPaletteOverlay`)
- IPC/CLI (`IPCCommandRouter` + `Sources/idx0`)

This is a key invariant: adding commands without parity creates behavioral drift.

## 5. Session Domain Architecture

`SessionService` is a facade split across concern extensions:

- Lifecycle: create/select/focus/rename/tab/pane primitives
- Runtime launch: controller creation, launch manifests, wrapper behavior, URL routing
- Session ops: close/relaunch/browser/tile-level operational behavior
- Layout persistence: tile state serialization + Niri layout normalization/migration
- Niri canvas ops: tile insertion/focus/movement/resize/workspace movement
- Utilities: path normalization, project grouping, attention sync, settings persistence helpers

Design intent:

- Keep orchestration in service layer.
- Keep models value-centric.
- Keep views mostly declarative consumers.

## 6. Workflow Domain Architecture

`WorkflowService` manages:

- checkpoints
- handoffs
- review requests
- approvals
- supervision queue
- timeline
- compare presets/results
- layout state for focus/park/stack/rail mode
- agent event ingestion and dedupe

Key extension slices:

- Collaboration operations (`+Collaboration`)
- Agent event ingestion + lifecycle loggers (`+EventIngestor`)
- Queue/layout/navigation/tool launch operations (`+QueueLayout`)

## 7. Data Flow Examples

### 7.1 Terminal state -> attention -> workflow

1. Terminal output is polled by `TerminalMonitorService`.
2. `AgentOutputScanner` classifies state (`thinking`, `working`, `waiting`, `completed`, `error`).
3. `SessionService` updates `Session.agentActivity` and status state.
4. `WorkflowService` may receive lifecycle callbacks and queue/timeline updates.

### 7.2 IPC command -> service behavior

1. External caller sends JSON request to Unix socket.
2. `IPCServer` decodes `IPCRequest` and forwards to `IPCCommandRouter` on main actor.
3. Router validates payload and delegates to `SessionService` / `WorkflowService`.
4. `IPCResponse` returns success + optional data payload.

### 7.3 Niri tile operation

1. Command/gesture triggers `SessionService+NiriCanvasOps` mutation.
2. Layout is normalized and focus camera updated.
3. Runtime controllers are created/removed through registry-driven descriptor callbacks.
4. UI reads resulting layout and controller state to render.

## 8. Persistence Architecture Summary

Stores and payloads are file-backed JSON with schema/version awareness:

- Sessions/projects/inbox/settings stores
- Workflow stores (queue/timeline/checkpoints/handoffs/reviews/approvals/layout/agent events)
- Tile-state persistence file for per-session tab/pane/Niri layout state

Corrupt data strategy generally favors backup-and-reset over crash.

See: `docs/architecture/persistence-and-state.md`.

## 9. Runtime and Integration Boundaries

- Ghostty runtime boundary: `idx0/Terminal/*` + C bridge headers/source.
- Launch wrapper/sandbox boundary: `SessionLauncher` + launch helper script generation.
- External tool discovery/launch boundary: `VibeCLIDiscoveryService`, `VibeCLILaunchService`, `ShellPoolService`.
- App tile integrations: `idx0/Apps/*` + `NiriAppRegistry` descriptors.

See: `docs/architecture/runtime-integrations.md`.

## 10. Current Maintainability Hotspots (from gate)

As of 2026-03-22, notable large/hot files include:

- `idx0/Apps/VSCode/VSCodeRuntime.swift` (exception-listed)
- `idx0/Apps/T3Code/T3CodeRuntime.swift`
- `idx0/Services/Session/SessionService+*.swift` slices (several >500 LOC)
- `idx0/Services/Workflow/WorkflowService.swift`
- `idx0/Terminal/GhosttyAppHost.swift`
- `idx0/Terminal/GhosttyTerminalSurface.swift`
- `idx0/UI/Workflow/WorkflowRailView.swift`

Treat edits here as high-risk and prefer small, tested slices.

## 11. Practical Extension Rules

- Prefer extending existing slice files over new cross-cutting helper classes.
- Add protocol seams before introducing test-hostile process/file dependencies.
- Preserve action and protocol parity when adding behavior.
- Keep persistence changes backward compatible by default.
