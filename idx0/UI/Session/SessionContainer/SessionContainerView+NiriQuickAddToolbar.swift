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

        items.append(TileSpotlightItem(
            id: "cmd-new-session",
            icon: "plus.circle",
            title: "New Quick Session",
            subtitle: "Create an instant terminal session",
            searchText: "new quick session instant terminal",
            shortcut: shortcutLabel(.newQuickSession),
            section: .commands,
            run: { _ = self.coordinator.performCommand(.newQuickSession) }
        ))

        items.append(TileSpotlightItem(
            id: "cmd-switch-session",
            icon: "arrow.left.arrow.right",
            title: "Quick Switch Session",
            subtitle: "Jump to a session by name",
            searchText: "switch session jump focus quick",
            shortcut: shortcutLabel(.quickSwitchSession),
            section: .commands,
            run: { _ = self.coordinator.performCommand(.quickSwitchSession) }
        ))

        items.append(TileSpotlightItem(
            id: "cmd-overview",
            icon: "square.grid.3x3",
            title: "Toggle Overview",
            subtitle: "Bird's-eye view of all tiles",
            searchText: "overview toggle canvas workspaces bird eye",
            shortcut: shortcutLabel(.niriToggleOverview),
            section: .commands,
            run: { _ = self.coordinator.performCommand(.niriToggleOverview) }
        ))

        items.append(TileSpotlightItem(
            id: "cmd-close-tile",
            icon: "xmark.rectangle",
            title: "Close Tile",
            subtitle: "Close the focused tile",
            searchText: "close tile pane remove",
            shortcut: shortcutLabel(.closePane),
            section: .commands,
            run: { _ = self.coordinator.performCommand(.closePane) }
        ))

        items.append(TileSpotlightItem(
            id: "cmd-toggle-sidebar",
            icon: "sidebar.left",
            title: "Toggle Sidebar",
            subtitle: "Show or hide the sidebar",
            searchText: "toggle sidebar show hide",
            shortcut: shortcutLabel(.toggleSidebar),
            section: .commands,
            run: { _ = self.coordinator.performCommand(.toggleSidebar) }
        ))

        items.append(TileSpotlightItem(
            id: "cmd-settings",
            icon: "gear",
            title: "Open Settings",
            subtitle: "Open IDX0 preferences",
            searchText: "settings preferences open",
            shortcut: shortcutLabel(.openSettings),
            section: .commands,
            run: { _ = self.coordinator.performCommand(.openSettings) }
        ))

        items.append(TileSpotlightItem(
            id: "cmd-shortcuts",
            icon: "keyboard",
            title: "Keyboard Shortcuts",
            subtitle: "View all keyboard shortcuts",
            searchText: "keyboard shortcuts help keys bindings",
            shortcut: shortcutLabel(.keyboardShortcuts),
            section: .commands,
            run: { _ = self.coordinator.performCommand(.keyboardShortcuts) }
        ))

        items.append(TileSpotlightItem(
            id: "cmd-rename",
            icon: "pencil",
            title: "Rename Session",
            subtitle: "Change the title of the current session",
            searchText: "rename session title",
            shortcut: shortcutLabel(.renameSession),
            section: .commands,
            run: { _ = self.coordinator.performCommand(.renameSession) }
        ))

        items.append(TileSpotlightItem(
            id: "cmd-snap",
            icon: "dot.scope",
            title: "Toggle Snap",
            subtitle: sessionService.settings.niri.snapEnabled ? "Disable snap" : "Enable velocity-based snap",
            searchText: "snap toggle velocity free pan",
            shortcut: shortcutLabel(.niriToggleSnap),
            section: .commands,
            run: { _ = self.coordinator.performCommand(.niriToggleSnap) }
        ))

        items.append(TileSpotlightItem(
            id: "cmd-tabbed",
            icon: "rectangle.tophalf.inset.filled",
            title: "Toggle Column Tabbed Display",
            subtitle: "Switch column between normal and tabbed",
            searchText: "tabbed column display mode toggle",
            shortcut: shortcutLabel(.niriToggleColumnTabbedDisplay),
            section: .commands,
            run: { _ = self.coordinator.performCommand(.niriToggleColumnTabbedDisplay) }
        ))

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
