import SwiftUI
import AppKit
import AppIntents

@main
struct idx0App: App {
    private static let idx0RepositoryURL = "https://github.com/galz10/idx0"

    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(coordinator)
                .environmentObject(coordinator.sessionService)
                .environmentObject(coordinator.workflowService)
                .environment(\.themeColors, themeColors)
                .frame(minWidth: 600, minHeight: 400)
                .preferredColorScheme(themeColors.isLight ? .light : .dark)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    coordinator.prepareForTermination()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    _ = coordinator.performCommand(.newSession)
                }
                .keyboardShortcut(shortcut(.newSession))

                Button("New Instant Terminal") {
                    _ = coordinator.performCommand(.newQuickSession)
                }
                .keyboardShortcut(shortcut(.newQuickSession))

                Button("New Repo/Worktree Session...") {
                    _ = coordinator.performCommand(.newRepoWorktreeSession)
                }
                .keyboardShortcut(shortcut(.newRepoWorktreeSession))

                Button("New Worktree Session...") {
                    _ = coordinator.performCommand(.newWorktreeSession)
                }
                .keyboardShortcut(shortcut(.newWorktreeSession))
            }

            CommandMenu("Window") {
                ForEach(1...9, id: \.self) { num in
                    Button("Switch to Project \(num)") {
                        coordinator.sessionService.focusProjectGroup(at: num)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(num)")), modifiers: .command)
                }

                Divider()

                Button("Next Session") {
                    _ = coordinator.performCommand(.focusNextSession)
                }
                .keyboardShortcut(shortcut(.focusNextSession))

                Button("Previous Session") {
                    _ = coordinator.performCommand(.focusPreviousSession)
                }
                .keyboardShortcut(shortcut(.focusPreviousSession))
            }

            CommandMenu("Session") {
                Button("Command Palette...") {
                    _ = coordinator.performCommand(.commandPalette)
                }
                .keyboardShortcut(shortcut(.commandPalette))

                Button("Quick Switch Session...") {
                    _ = coordinator.performCommand(.quickSwitchSession)
                }
                .keyboardShortcut(shortcut(.quickSwitchSession))

                Button("Keyboard Shortcuts...") {
                    coordinator.showingKeyboardShortcuts = true
                }

                Button("Niri Onboarding (Show Now)") {
                    coordinator.presentNiriOnboardingNow()
                }

                Divider()

                Button("Show Diff") {
                    _ = coordinator.performCommand(.showDiff)
                }
                .keyboardShortcut(shortcut(.showDiff))

                Button("Checkpoints") {
                    _ = coordinator.performCommand(.showCheckpoints)
                }
                .keyboardShortcut(shortcut(.showCheckpoints))

                Button("Quick Approve") {
                    _ = coordinator.performCommand(.quickApprove)
                }
                .keyboardShortcut(shortcut(.quickApprove))

                Divider()

                Button("Toggle Focus Mode") {
                    _ = coordinator.performCommand(.toggleFocusMode)
                }
                .keyboardShortcut(shortcut(.toggleFocusMode))

                Button("Rename Session") {
                    _ = coordinator.performCommand(.renameSession)
                }
                .keyboardShortcut(shortcut(.renameSession))

                Button("Close Session") {
                    _ = coordinator.performCommand(.closeSession)
                }
                .keyboardShortcut(shortcut(.closeSession))

                Divider()

                Button("Relaunch Session") {
                    _ = coordinator.performCommand(.relaunchSession)
                }
                .keyboardShortcut(shortcut(.relaunchSession))

                Button("Relaunch All Sessions") {
                    coordinator.sessionService.relaunchAllSessions()
                }

                Divider()

                Button("New Tab") {
                    _ = coordinator.performCommand(.newTab)
                }
                .keyboardShortcut(shortcut(.newTab))

                Button("Next Tab") {
                    _ = coordinator.performCommand(.nextTab)
                }
                .keyboardShortcut(shortcut(.nextTab))

                Button("Previous Tab") {
                    _ = coordinator.performCommand(.previousTab)
                }
                .keyboardShortcut(shortcut(.previousTab))

                Button("Close Tab") {
                    _ = coordinator.performCommand(.closeTab)
                }
                .keyboardShortcut(shortcut(.closeTab))

                Divider()

                Button("Niri: Add Terminal Right") {
                    guard coordinator.sessionService.selectedSessionID != nil else { return }
                    _ = coordinator.performCommand(.niriAddTerminalRight)
                }
                .keyboardShortcut(shortcut(.niriAddTerminalRight))
                .disabled(!coordinator.sessionService.settings.niriCanvasEnabled)

                Button("Niri: Add Task Below") {
                    guard coordinator.sessionService.selectedSessionID != nil else { return }
                    _ = coordinator.performCommand(.niriAddTaskBelow)
                }
                .keyboardShortcut(shortcut(.niriAddTaskBelow))
                .disabled(!coordinator.sessionService.settings.niriCanvasEnabled)

                Button("Niri: Add Browser Tile") {
                    guard coordinator.sessionService.selectedSessionID != nil else { return }
                    _ = coordinator.performCommand(.niriAddBrowserTile)
                }
                .keyboardShortcut(shortcut(.niriAddBrowserTile))
                .disabled(!coordinator.sessionService.settings.niriCanvasEnabled)

                Button("Niri: Open Add Tile Menu") {
                    _ = coordinator.performCommand(.niriOpenAddTileMenu)
                }
                .keyboardShortcut(shortcut(.niriOpenAddTileMenu))
                .disabled(!coordinator.sessionService.settings.niriCanvasEnabled)

                ForEach(NiriAppUIVisibility.appMenuApps(from: coordinator.sessionService.registeredNiriApps), id: \.id) { app in
                    Button("Niri: Add \(app.displayName) Tile") {
                        guard let selected = coordinator.sessionService.selectedSessionID else { return }
                        _ = coordinator.sessionService.niriAddAppRight(in: selected, appID: app.id)
                    }
                    .disabled(!coordinator.sessionService.settings.niriCanvasEnabled)
                }

                Button("VS Code: Setup Browser Debug (idx-web)") {
                    guard let selected = coordinator.sessionService.selectedSessionID else { return }
                    _ = coordinator.sessionService.setupVSCodeBrowserDebug(for: selected)
                }
                .disabled(!coordinator.sessionService.settings.niriCanvasEnabled)

                Button("Niri: Focus Right") {
                    guard coordinator.sessionService.selectedSessionID != nil else { return }
                    _ = coordinator.performCommand(.niriFocusRight)
                }
                .keyboardShortcut(shortcut(.niriFocusRight))
                .disabled(!coordinator.sessionService.settings.niriCanvasEnabled)

                Button("Niri: Focus Left") {
                    guard coordinator.sessionService.selectedSessionID != nil else { return }
                    _ = coordinator.performCommand(.niriFocusLeft)
                }
                .keyboardShortcut(shortcut(.niriFocusLeft))
                .disabled(!coordinator.sessionService.settings.niriCanvasEnabled)

                Button("Niri: Focus Down") {
                    guard coordinator.sessionService.selectedSessionID != nil else { return }
                    _ = coordinator.performCommand(.niriFocusDown)
                }
                .keyboardShortcut(shortcut(.niriFocusDown))
                .disabled(!coordinator.sessionService.settings.niriCanvasEnabled)

                Button("Niri: Focus Up") {
                    guard coordinator.sessionService.selectedSessionID != nil else { return }
                    _ = coordinator.performCommand(.niriFocusUp)
                }
                .keyboardShortcut(shortcut(.niriFocusUp))
                .disabled(!coordinator.sessionService.settings.niriCanvasEnabled)

                Button("Niri: Toggle Overview") {
                    guard coordinator.sessionService.selectedSessionID != nil else { return }
                    _ = coordinator.performCommand(.niriToggleOverview)
                }
                .keyboardShortcut(shortcut(.niriToggleOverview))
                .disabled(!coordinator.sessionService.settings.niriCanvasEnabled)

                Button("Niri: Confirm Selection") {
                    guard let selected = coordinator.sessionService.selectedSessionID else { return }
                    let layout = coordinator.sessionService.niriLayout(for: selected)
                    if layout.isOverviewOpen {
                        _ = coordinator.performCommand(.niriToggleOverview)
                    }
                }
                .keyboardShortcut(shortcut(.niriConfirmSelection))
                .disabled(!coordinator.sessionService.settings.niriCanvasEnabled || {
                    guard let selected = coordinator.sessionService.selectedSessionID else { return true }
                    return !coordinator.sessionService.niriLayout(for: selected).isOverviewOpen
                }())

                Button("Niri: Toggle Column Tabbed Display") {
                    guard coordinator.sessionService.selectedSessionID != nil else { return }
                    _ = coordinator.performCommand(.niriToggleColumnTabbedDisplay)
                }
                .keyboardShortcut(shortcut(.niriToggleColumnTabbedDisplay))
                .disabled(!coordinator.sessionService.settings.niriCanvasEnabled)

                Button("Niri: Toggle Focused Tile Zoom") {
                    guard coordinator.sessionService.selectedSessionID != nil else { return }
                    _ = coordinator.performCommand(.niriToggleFocusedTileZoom)
                }
                .keyboardShortcut(shortcut(.niriToggleFocusedTileZoom))
                .disabled(!coordinator.sessionService.settings.niriCanvasEnabled)

                Button("Niri: Toggle Snap") {
                    _ = coordinator.performCommand(.niriToggleSnap)
                }
                .keyboardShortcut(shortcut(.niriToggleSnap))
                .disabled(!coordinator.sessionService.settings.niriCanvasEnabled)

                Button("Niri: Focus Workspace Down") {
                    guard coordinator.sessionService.selectedSessionID != nil else { return }
                    _ = coordinator.performCommand(.niriFocusWorkspaceDown)
                }
                .keyboardShortcut(shortcut(.niriFocusWorkspaceDown))
                .disabled(!coordinator.sessionService.settings.niriCanvasEnabled)

                Button("Niri: Focus Workspace Up") {
                    guard coordinator.sessionService.selectedSessionID != nil else { return }
                    _ = coordinator.performCommand(.niriFocusWorkspaceUp)
                }
                .keyboardShortcut(shortcut(.niriFocusWorkspaceUp))
                .disabled(!coordinator.sessionService.settings.niriCanvasEnabled)

                Button("Niri: Move Column To Workspace Down") {
                    guard coordinator.sessionService.selectedSessionID != nil else { return }
                    _ = coordinator.performCommand(.niriMoveColumnToWorkspaceDown)
                }
                .keyboardShortcut(shortcut(.niriMoveColumnToWorkspaceDown))
                .disabled(!coordinator.sessionService.settings.niriCanvasEnabled)

                Button("Niri: Move Column To Workspace Up") {
                    guard coordinator.sessionService.selectedSessionID != nil else { return }
                    _ = coordinator.performCommand(.niriMoveColumnToWorkspaceUp)
                }
                .keyboardShortcut(shortcut(.niriMoveColumnToWorkspaceUp))
                .disabled(!coordinator.sessionService.settings.niriCanvasEnabled)

                Divider()

                Button(coordinator.sessionService.settings.niriCanvasEnabled ? "Niri: Add Terminal Right" : "Split Pane Right") {
                    if coordinator.sessionService.selectedSessionID != nil {
                        if coordinator.sessionService.settings.niriCanvasEnabled {
                            _ = coordinator.performCommand(.niriAddTerminalRight)
                        } else {
                            _ = coordinator.performCommand(.splitRight)
                        }
                    }
                }
                .keyboardShortcut(shortcut(.splitRight))

                Button(coordinator.sessionService.settings.niriCanvasEnabled ? "Niri: Add Task Below" : "Split Pane Down") {
                    if coordinator.sessionService.selectedSessionID != nil {
                        if coordinator.sessionService.settings.niriCanvasEnabled {
                            _ = coordinator.performCommand(.niriAddTaskBelow)
                        } else {
                            _ = coordinator.performCommand(.splitDown)
                        }
                    }
                }
                .keyboardShortcut(shortcut(.splitDown))

                Button("Close Pane") {
                    _ = coordinator.performCommand(.closePane)
                }
                .keyboardShortcut(shortcut(.closePane))

                Button("Next Pane") {
                    if coordinator.sessionService.selectedSessionID != nil {
                        _ = coordinator.performCommand(.nextPane)
                    }
                }
                .keyboardShortcut(shortcut(.nextPane))

                Button("Previous Pane") {
                    if coordinator.sessionService.selectedSessionID != nil {
                        _ = coordinator.performCommand(.previousPane)
                    }
                }
                .keyboardShortcut(shortcut(.previousPane))

                Divider()

                Button("Toggle Browser Split") {
                    if coordinator.sessionService.selectedSessionID != nil {
                        _ = coordinator.performCommand(.toggleBrowserSplit)
                    }
                }
                .keyboardShortcut(shortcut(.toggleBrowserSplit))

                Button("Open Clipboard URL In Split") {
                    _ = coordinator.performCommand(.openClipboardURL)
                }
                .keyboardShortcut(shortcut(.openClipboardURL))

                Divider()

                Button("Toggle Sidebar") {
                    _ = coordinator.performCommand(.toggleSidebar)
                }
                .keyboardShortcut(shortcut(.toggleSidebar))
            }

            CommandGroup(after: .help) {
                Button("Get IDX0") {
                    openIDX0Repository()
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    _ = coordinator.performCommand(.openSettings)
                }
                .keyboardShortcut(shortcut(.openSettings))
            }
        }

    }

    private var themeColors: AppThemeColors {
        TerminalTheme.resolveColors(themeID: coordinator.sessionService.settings.terminalThemeID)
    }

    private func shortcut(_ action: ShortcutActionID) -> KeyChord? {
        ShortcutRegistry.shared.primaryBinding(for: action, settings: coordinator.sessionService.settings)
    }

    private func openIDX0Repository() {
        guard let url = URL(string: Self.idx0RepositoryURL) else { return }
        NSWorkspace.shared.open(url)
    }
}
