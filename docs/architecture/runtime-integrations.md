# Runtime Integrations

This guide covers major runtime and external integration systems in `idx0`.

## 1. Ghostty Integration

Primary files:

- `idx0/Terminal/GhosttyAppHost.swift`
- `idx0/Terminal/GhosttyTerminalSurface.swift`
- `idx0/Terminal/GhosttyTerminalView.swift`
- `idx0/Terminal/MultiPaneTerminalView.swift`
- `idx0/Terminal/idx0_GhosttyBridge.c`
- `ghostty.h`, `idx0-GhosttyBridge.h`, `idx0-Bridging-Header.h`

Responsibilities:

- Dynamic/runtime initialization of ghostty app + config.
- Native surface lifecycle create/focus/resize/refresh/teardown.
- Clipboard, URL action, callback routing into Swift layer.
- Scrollback dump used by `TerminalMonitorService`.

Contributor notes:

- Surface creation timing is sensitive to AppKit view/window lifecycle.
- Occlusion and tick scheduling are critical for rendering behavior.
- Multi-pane mode uses custom container behavior separate from single-surface portal flow.

## 2. Launch Wrapper and Sandbox Pipeline

Primary files:

- `idx0/Services/Session/SessionLauncher.swift`
- `idx0/Services/Session/SessionService+RuntimeLaunch.swift`

How it works:

1. Service resolves launch manifest (`cwd`, shell, repo/worktree context, sandbox/network policy).
2. Launcher persists manifest and generates wrapper/helper scripts.
3. Session controller launches wrapper path (not direct shell in restricted mode).
4. Wrapper writes launch-result status (enforced/degraded/unenforced).
5. Service maps result into session status text and enforcement state.

Profiles:

- `fullAccess`
- `worktreeWrite`
- `worktreeAndTemp`

Behavior emphasis is graceful degradation with explicit status messages.

## 3. Shell and Tool Discovery/Launch

Primary files:

- `idx0/Services/Runtime/ShellPoolService.swift`
- `idx0/Services/Runtime/VibeCLIDiscoveryService.swift`
- `idx0/Services/Runtime/VibeCLILaunchService.swift`
- `idx0/Services/Session/ShellIntegrationHealthService.swift`

Highlights:

- ShellPool warms default shell resolution and tool discovery.
- Discovery checks PATH + common fallback directories + login shell fallback.
- Tool launch injects command into running terminal controller.
- Tool catalog defined in `idx0/Models/VibeCLITool.swift`.

## 4. Embedded Browser Integration

Primary files:

- `idx0/Services/Session/SessionBrowserController.swift`
- `idx0/Services/Browser/BrowserDataStore.swift`
- `idx0/Services/Browser/ChromeCookieImporter.swift`

Highlights:

- Browser controller uses `WKWebView` with KVO-backed state updates.
- Shared browser bookmarks/history are persisted under app support.
- One-time cookie hydration imports Chrome cookies for smoother auth continuity.

## 5. Niri App Tile Runtime Integration

Core abstraction:

- `NiriAppDescriptor` in `idx0/Apps/Core/NiriAppRegistry.swift`
- `NiriAppTileRuntimeControlling` protocol

Current built-ins:

- `t3-code` tile runtime (`idx0/Apps/T3Code/T3CodeRuntime.swift`)
- `vscode` tile runtime (`idx0/Apps/VSCode/VSCodeRuntime.swift`)
- `excalidraw` tile runtime (`idx0/Apps/Excalidraw/ExcalidrawRuntime.swift`)
- `opencode` tile runtime (`idx0/Apps/OpenCode/OpenCodeRuntime.swift`)

Descriptor fields define:

- create/retry/stop hooks
- controller creation
- tile view rendering
- optional cleanup callbacks per session

### Adding a New Niri App Tile

1. Implement runtime controller conforming to `NiriAppTileRuntimeControlling`.
2. Add app-specific runtime state model and provisioning paths if needed.
3. Provide descriptor callbacks for create/retry/stop/ensure/view/cleanup.
4. Register descriptor during session service startup.
5. Add Niri tests for creation, reuse, cleanup, and zoom/retry behavior.

## 6. T3 Runtime Details

Primary file: `idx0/Apps/T3Code/T3CodeRuntime.swift`

Key capabilities:

- Manifest-driven clone/build/run flow (`t3-build-manifest.json`)
- Build reuse when artifacts and build record match pinned commit
- Session snapshot directories under app support
- Runtime state surfaced to tile UI (`idle`, `building`, `live`, `failed`, etc.)

## 7. VSCode Runtime Details

Primary file: `idx0/Apps/VSCode/VSCodeRuntime.swift`

Key capabilities:

- Manifest-driven code-server runtime install (`openvscode-build-manifest.json`)
- Platform-specific artifact resolution + SHA validation
- Reusable runtime install record
- Per-session user-data/extensions directories with profile seeding
- Runtime state surfaced to tile UI (`provisioning`, `downloading`, `live`, etc.)

## 8. Excalidraw Runtime Details

Primary file: `idx0/Apps/Excalidraw/ExcalidrawRuntime.swift`

Key capabilities:

- Manifest-driven clone/build/run flow (`excalidraw-build-manifest.json`)
- Build reuse when artifacts and build record match pinned commit
- Session-stable origin mapping via persisted loopback port assignment
- Local static serving into `WKWebView` with retryable startup behavior
- Runtime state surfaced to tile UI (`preparingSource`, `building`, `live`, etc.)

## 9. OpenCode Runtime Details

Primary file: `idx0/Apps/OpenCode/OpenCodeRuntime.swift`

Key capabilities:

- Launches OpenCode in serve mode without auto-opening a browser.
- Uses per-session isolated `XDG_*` directories under app support.
- Probes readiness via `GET /global/health` before loading tile `WKWebView`.
- Captures runtime stdout/stderr into per-session runtime logs.
- Supports retry/stop/log-open and in-tile web zoom adjustments.

## 10. Integration Risk Checklist

Before merging integration changes:

- [ ] Launch fallback behavior still works without hard crash.
- [ ] Terminal focus/occlusion behavior verified manually.
- [ ] Session close correctly tears down runtime controllers.
- [ ] Persisted state paths are stable across relaunch.
- [ ] Test coverage added for install/build/cleanup or controller lifecycle.
