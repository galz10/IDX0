import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

extension SessionContainerView {
    func niriCanvasToolbar(sessionID: UUID, layout: NiriCanvasLayout) -> some View {
        let activeWorkspace = niriActiveWorkspaceIndex(layout: layout).map { $0 + 1 } ?? 1
        let activeColumn = niriActiveColumnIndex(
            layout: layout,
            workspaceIndex: niriActiveWorkspaceIndex(layout: layout) ?? 0
        ).map { $0 + 1 } ?? 1

        return HStack(spacing: 8) {
            Text("w\(activeWorkspace) · c\(activeColumn)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(tc.tertiaryText)

            if layout.isOverviewOpen {
                Text("Overview")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tc.accent.opacity(0.8))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tc.accent.opacity(0.1), in: Capsule())
            }

            if sessionService.settings.niri.snapEnabled {
                Text("Snap")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tc.tertiaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tc.surface1.opacity(0.8), in: Capsule())
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(height: 28)
        .background(tc.windowBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tc.divider)
                .frame(height: 1)
        }
    }

    // MARK: - Expanding + Button / Spotlight

    @ViewBuilder
    func niriCanvasQuickAddButton(sessionID: UUID) -> some View {
        if niriQuickAddMenuPresented {
            // Expanded spotlight
            NiriTileSpotlight(
                isPresented: $niriQuickAddMenuPresented,
                items: niriAllSpotlightItems(sessionID: sessionID)
            )
            .transition(.asymmetric(
                insertion: .scale(scale: 0.9, anchor: .topLeading)
                    .combined(with: .opacity),
                removal: .scale(scale: 0.95, anchor: .topLeading)
                    .combined(with: .opacity)
            ))
        } else {
            // Collapsed + button
            Button {
                withAnimation(.spring(duration: 0.25, bounce: 0.1)) {
                    niriQuickAddMenuPresented = true
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tc.primaryText)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(tc.surface1.opacity(0.95))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(tc.divider.opacity(0.9), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 2)
            .help("Add Tile (\(niriAddTileShortcutLabel))")
            .transition(.scale(scale: 0.8, anchor: .topLeading).combined(with: .opacity))
        }
    }

    // MARK: - All Spotlight Items (Tiles + Commands)

    func niriAllSpotlightItems(sessionID: UUID) -> [TileSpotlightItem] {
        var items: [TileSpotlightItem] = []

        // -- Tile section --

        // Terminal
        items.append(TileSpotlightItem(
            id: "terminal",
            icon: "terminal",
            title: "Terminal",
            subtitle: "New terminal tile",
            searchText: "terminal shell console bash zsh new tile add",
            shortcut: shortcutLabel(.niriAddTerminalRight),
            section: .apps,
            run: {
                _ = self.sessionService.niriAddTerminalRight(in: sessionID)
            }
        ))

        // Registered apps
        let visibleApps = NiriAppUIVisibility.quickAddApps(from: sessionService.registeredNiriApps)
        for app in visibleApps {
            items.append(TileSpotlightItem(
                id: "app-\(app.id)",
                icon: app.icon,
                iconImageName: app.iconImageName,
                title: app.displayName,
                subtitle: app.menuSubtitle,
                searchText: "\(app.displayName.lowercased()) \(app.id) \(app.menuSubtitle.lowercased()) app tile add",
                section: .apps,
                run: {
                    _ = self.sessionService.niriAddAppRight(in: sessionID, appID: app.id)
                }
            ))
        }

        // Browser
        items.append(TileSpotlightItem(
            id: "browser",
            icon: "globe",
            title: "Browser",
            subtitle: "Open web view tile",
            searchText: "browser web view globe url http tile add",
            section: .apps,
            run: {
                _ = self.sessionService.niriAddBrowserRight(in: sessionID)
            }
        ))

        // Agentic CLIs
        let installedTools = workflowService.vibeTools.filter(\.isInstalled)
        for tool in installedTools {
            items.append(TileSpotlightItem(
                id: "tool-\(tool.id)",
                icon: niriToolIconName(for: tool.id),
                title: tool.displayName,
                subtitle: tool.executableName,
                searchText: "\(tool.displayName.lowercased()) \(tool.executableName.lowercased()) cli agent agentic tool tile add",
                section: .tools,
                run: {
                    self.niriLaunchToolInNewTile(sessionID: sessionID, toolID: tool.id)
                }
            ))
        }

        // -- Commands section --
        let selected = sessionService.selectedSession
        let selectedID = selected?.id
        let hasWorktree = selected?.worktreePath != nil
        let showsVibe = sessionService.settings.appMode.showsVibeFeatures

        func appendCommand(
            id: String,
            icon: String,
            title: String,
            subtitle: String,
            searchText: String,
            shortcutAction: ShortcutActionID? = nil,
            run: @escaping () -> Void
        ) {
            items.append(TileSpotlightItem(
                id: id,
                icon: icon,
                title: title,
                subtitle: subtitle,
                searchText: searchText,
                shortcut: shortcutAction.flatMap { shortcutLabel($0) },
                section: .commands,
                run: run
            ))
        }

        appendCommand(
            id: "cmd-new-quick-session",
            icon: "plus.circle",
            title: "New Quick Session",
            subtitle: "Create an instant terminal session",
            searchText: "new quick session instant terminal",
            shortcutAction: .newQuickSession,
            run: { _ = self.coordinator.performCommand(.newQuickSession) }
        )
        appendCommand(
            id: "cmd-new-repo-session",
            icon: "folder",
            title: "New Repo/Worktree Session",
            subtitle: "Open structured setup for repo or worktree",
            searchText: "new repo worktree structured session setup",
            shortcutAction: .newRepoWorktreeSession,
            run: { _ = self.coordinator.performCommand(.newRepoWorktreeSession) }
        )
        appendCommand(
            id: "cmd-switch-session",
            icon: "arrow.left.arrow.right",
            title: "Quick Switch Session",
            subtitle: "Jump to a session by name",
            searchText: "switch session jump focus quick",
            shortcutAction: .quickSwitchSession,
            run: { _ = self.coordinator.performCommand(.quickSwitchSession) }
        )
        appendCommand(
            id: "cmd-rename",
            icon: "pencil",
            title: "Rename Session",
            subtitle: "Change the title of the current session",
            searchText: "rename session title",
            shortcutAction: .renameSession,
            run: { _ = self.coordinator.performCommand(.renameSession) }
        )
        appendCommand(
            id: "cmd-close-session",
            icon: "xmark",
            title: "Close Session",
            subtitle: "Close the current session",
            searchText: "close session",
            shortcutAction: .closeSession,
            run: { _ = self.coordinator.performCommand(.closeSession) }
        )
        appendCommand(
            id: "cmd-relaunch-session",
            icon: "arrow.clockwise",
            title: "Relaunch Session",
            subtitle: "Restart the current terminal session",
            searchText: "relaunch session restart terminal",
            shortcutAction: .relaunchSession,
            run: { _ = self.coordinator.performCommand(.relaunchSession) }
        )
        appendCommand(
            id: "cmd-add-terminal-right",
            icon: "rectangle.split.2x1",
            title: "Niri: Add Terminal Right",
            subtitle: "Create a terminal tile to the right",
            searchText: "split pane right vertical niri terminal",
            shortcutAction: .splitRight,
            run: { _ = self.coordinator.performCommand(.splitRight) }
        )
        appendCommand(
            id: "cmd-add-task-below",
            icon: "rectangle.split.1x2",
            title: "Niri: Add Task Below",
            subtitle: "Create a terminal tile below in this task stack",
            searchText: "split pane down horizontal niri task below",
            shortcutAction: .splitDown,
            run: { _ = self.coordinator.performCommand(.splitDown) }
        )
        appendCommand(
            id: "cmd-open-add-tile-menu",
            icon: "plus.circle",
            title: "Add Tile",
            subtitle: "Open the tile spotlight to add a new tile",
            searchText: "add tile spotlight new terminal browser app plus",
            shortcutAction: .niriOpenAddTileMenu,
            run: { _ = self.coordinator.performCommand(.niriOpenAddTileMenu) }
        )
        appendCommand(
            id: "cmd-overview",
            icon: "square.grid.3x3",
            title: "Niri: Toggle Overview",
            subtitle: "Open or close Niri overview mode",
            searchText: "niri overview toggle canvas workspaces bird eye",
            shortcutAction: .niriToggleOverview,
            run: { _ = self.coordinator.performCommand(.niriToggleOverview) }
        )
        appendCommand(
            id: "cmd-tabbed",
            icon: "rectangle.tophalf.inset.filled",
            title: "Niri: Toggle Column Tabbed Display",
            subtitle: "Switch focused column between normal and tabbed",
            searchText: "niri toggle tabbed column display mode",
            shortcutAction: .niriToggleColumnTabbedDisplay,
            run: { _ = self.coordinator.performCommand(.niriToggleColumnTabbedDisplay) }
        )
        appendCommand(
            id: "cmd-focused-zoom",
            icon: "arrow.up.left.and.arrow.down.right",
            title: "Niri: Toggle Focused Tile Zoom",
            subtitle: "Make the focused tile fill the canvas viewport",
            searchText: "niri focused tile zoom fullscreen max",
            shortcutAction: .niriToggleFocusedTileZoom,
            run: { _ = self.coordinator.performCommand(.niriToggleFocusedTileZoom) }
        )
        appendCommand(
            id: "cmd-snap",
            icon: "dot.scope",
            title: "Niri: Toggle Snap",
            subtitle: sessionService.settings.niri.snapEnabled ? "Disable snap and keep free-pan release" : "Enable velocity-based snap",
            searchText: "niri snap soft snap free pan velocity",
            shortcutAction: .niriToggleSnap,
            run: { _ = self.coordinator.performCommand(.niriToggleSnap) }
        )
        appendCommand(
            id: "cmd-focus-workspace-down",
            icon: "arrow.down.to.line",
            title: "Niri: Focus Workspace Down",
            subtitle: "Move focus to the next workspace",
            searchText: "niri workspace down focus next",
            shortcutAction: .niriFocusWorkspaceDown,
            run: { _ = self.coordinator.performCommand(.niriFocusWorkspaceDown) }
        )
        appendCommand(
            id: "cmd-focus-workspace-up",
            icon: "arrow.up.to.line",
            title: "Niri: Focus Workspace Up",
            subtitle: "Move focus to the previous workspace",
            searchText: "niri workspace up focus previous",
            shortcutAction: .niriFocusWorkspaceUp,
            run: { _ = self.coordinator.performCommand(.niriFocusWorkspaceUp) }
        )
        appendCommand(
            id: "cmd-move-column-down",
            icon: "arrow.down.square",
            title: "Niri: Move Column To Workspace Down",
            subtitle: "Move focused column to the next workspace",
            searchText: "niri move column workspace down",
            shortcutAction: .niriMoveColumnToWorkspaceDown,
            run: { _ = self.coordinator.performCommand(.niriMoveColumnToWorkspaceDown) }
        )
        appendCommand(
            id: "cmd-move-column-up",
            icon: "arrow.up.square",
            title: "Niri: Move Column To Workspace Up",
            subtitle: "Move focused column to the previous workspace",
            searchText: "niri move column workspace up",
            shortcutAction: .niriMoveColumnToWorkspaceUp,
            run: { _ = self.coordinator.performCommand(.niriMoveColumnToWorkspaceUp) }
        )
        appendCommand(
            id: "cmd-close-tile",
            icon: "xmark.rectangle",
            title: "Close Tile",
            subtitle: "Close the focused tile",
            searchText: "close tile pane remove",
            shortcutAction: .closePane,
            run: { _ = self.coordinator.performCommand(.closePane) }
        )
        appendCommand(
            id: "cmd-toggle-sidebar",
            icon: "sidebar.left",
            title: "Toggle Sidebar",
            subtitle: "Show or hide the sidebar",
            searchText: "toggle sidebar show hide",
            shortcutAction: .toggleSidebar,
            run: { _ = self.coordinator.performCommand(.toggleSidebar) }
        )
        appendCommand(
            id: "cmd-settings",
            icon: "gear",
            title: "Open Settings",
            subtitle: "Open IDX0 preferences",
            searchText: "settings preferences open",
            shortcutAction: .openSettings,
            run: { _ = self.coordinator.performCommand(.openSettings) }
        )
        appendCommand(
            id: "cmd-shortcuts",
            icon: "keyboard",
            title: "Keyboard Shortcuts",
            subtitle: "View all keyboard shortcuts",
            searchText: "keyboard shortcuts help keys bindings",
            shortcutAction: .keyboardShortcuts,
            run: { _ = self.coordinator.performCommand(.keyboardShortcuts) }
        )

        appendCommand(
            id: "cmd-vscode-setup-browser-debug",
            icon: "ladybug",
            title: "VS Code: Setup Browser Debug (idx-web)",
            subtitle: "Create/update launch.json attach config and launch Chromium debug browser",
            searchText: "vscode browser debug attach chrome launch json idx-web",
            run: {
                if let id = selectedID {
                    _ = self.sessionService.setupVSCodeBrowserDebug(for: id)
                }
            }
        )

        for session in sessionService.sessions where session.id != selectedID {
            items.append(TileSpotlightItem(
                id: "cmd-switch-\(session.id.uuidString)",
                icon: session.isWorktreeBacked ? "arrow.triangle.branch" : "terminal",
                title: "Switch to: \(session.title)",
                subtitle: session.subtitle,
                searchText: "switch \(session.title.lowercased()) \(session.subtitle.lowercased())",
                section: .commands,
                run: { [id = session.id] in self.sessionService.focusSession(id) }
            ))
        }

        if showsVibe {
            appendCommand(
                id: "cmd-create-checkpoint",
                icon: "bookmark",
                title: "Create Checkpoint",
                subtitle: "Save current state of selected session",
                searchText: "create checkpoint save state",
                shortcutAction: .showCheckpoints,
                run: {
                    guard let id = selectedID else { return }
                    Task {
                        _ = try? await self.workflowService.createManualCheckpoint(
                            sessionID: id,
                            title: "Manual Checkpoint",
                            summary: "Created from spotlight",
                            requestReview: false
                        )
                    }
                }
            )
            appendCommand(
                id: "cmd-toggle-rail",
                icon: "tray.full",
                title: "Toggle Workflow Rail",
                subtitle: "Show or hide the supervision panel",
                searchText: "toggle workflow rail inbox supervision panel",
                shortcutAction: .toggleWorkflowRail,
                run: { _ = self.coordinator.performCommand(.toggleWorkflowRail) }
            )
            appendCommand(
                id: "cmd-focus-queue",
                icon: "exclamationmark.circle",
                title: "Focus Next Queue Item",
                subtitle: "Jump to the highest-priority unresolved item",
                searchText: "focus queue next item priority",
                shortcutAction: .focusNextQueueItem,
                run: { _ = self.coordinator.performCommand(.focusNextQueueItem) }
            )
            appendCommand(
                id: "cmd-reveal-worktree",
                icon: "folder.badge.questionmark",
                title: "Reveal Worktree in Finder",
                subtitle: "Open worktree directory in Finder",
                searchText: "reveal worktree finder",
                run: {
                    if hasWorktree, let id = selectedID {
                        self.sessionService.revealWorktree(for: id)
                    }
                }
            )
        }

        return items
    }

    private func shortcutLabel(_ action: ShortcutActionID) -> String? {
        ShortcutRegistry.shared.displayLabel(for: action, settings: sessionService.settings)
    }

    private var niriAddTileShortcutLabel: String {
        shortcutLabel(.niriOpenAddTileMenu) ?? "+"
    }

    func niriLaunchToolInNewTile(sessionID: UUID, toolID: String) {
        guard sessionService.sessions.contains(where: { $0.id == sessionID }) else { return }
        _ = sessionService.niriAddTerminalRight(in: sessionID)
        do {
            try workflowService.launchTool(toolID, in: sessionID)
        } catch {
            sessionService.postStatusMessage(error.localizedDescription, for: sessionID)
        }
    }

    func niriToolIconName(for toolID: String) -> String {
        switch toolID {
        case "claude":
            return "text.bubble"
        case "codex":
            return "terminal"
        case "gemini-cli":
            return "sparkles"
        case "opencode":
            return "chevron.left.forwardslash.chevron.right"
        case "droid":
            return "cpu"
        default:
            return "terminal"
        }
    }

}
