import SwiftUI

struct CommandPaletteOverlay: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var sessionService: SessionService
    @EnvironmentObject private var workflowService: WorkflowService
    @Environment(\.themeColors) private var tc

    @FocusState private var queryFocused: Bool
    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var hoverReady = false
    @State private var lastSelectionSource: SelectionSource = .keyboard
    private enum SelectionSource { case keyboard, hover }

    var body: some View {
        ZStack {
            // Invisible dismiss layer (no dimming)
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                // Search field
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tc.accent)

                    TextField("Search...", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($queryFocused)
                        .onSubmit { executeSelected() }
                        .onChange(of: query) { _, _ in selectedIndex = 0 }

                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(tc.tertiaryText)
                        }
                        .buttonStyle(.plain)
                        .idxHitTarget()
                    }

                    keyBadge("esc")
                        .idxHitTarget()
                        .onTapGesture { dismiss() }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

                Rectangle()
                    .fill(tc.divider)
                    .frame(height: 1)

                // Results
                if !filteredActions.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(filteredActions.prefix(12).enumerated()), id: \.element.id) { index, action in
                                    paletteRow(action: action, isSelected: index == selectedIndex)
                                        .id(action.id)
                                        .onTapGesture {
                                            guard action.isEnabled else { return }
                                            selectedIndex = index
                                            executeSelected()
                                        }
                                        .onHover { hovering in
                                            guard hoverReady, hovering, action.isEnabled else { return }
                                            lastSelectionSource = .hover
                                            selectedIndex = index
                                        }
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 360)
                        .scrollIndicators(.hidden)
                        .onChange(of: selectedIndex) { _, newValue in
                            guard lastSelectionSource == .keyboard else { return }
                            if let action = filteredActions.prefix(12).dropFirst(newValue).first {
                                withAnimation(.easeOut(duration: 0.08)) {
                                    proxy.scrollTo(action.id, anchor: .center)
                                }
                            }
                        }
                    }
                } else {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10))
                            .foregroundStyle(tc.tertiaryText)
                        Text("No results for \"\(query)\"")
                            .font(.system(size: 11))
                            .foregroundStyle(tc.tertiaryText)
                    }
                    .padding(12)
                }
            }
            .frame(width: 420)
            .background(tc.sidebarBackground, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(tc.surface2.opacity(0.4), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 20, y: 6)
            .padding(.top, 60)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            hoverReady = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                queryFocused = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                hoverReady = true
            }
        }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
    }

    @ViewBuilder
    private func paletteRow(action: PaletteAction, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if let imageName = action.iconImageName {
                    Image(imageName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 13, height: 13)
                } else {
                    Image(systemName: action.icon)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(
                !action.isEnabled ? tc.mutedText :
                isSelected ? tc.accent : tc.secondaryText
            )
            .frame(width: 24, height: 24)
            .background(
                !action.isEnabled ? tc.surface0 :
                isSelected ? tc.accent.opacity(0.1) : tc.surface1,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(highlightedTitle(action.title))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(action.isEnabled ? tc.primaryText : tc.tertiaryText)
                    .lineLimit(1)

                Text(action.detail)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(tc.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let shortcut = action.shortcut {
                keyBadge(shortcut)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isSelected ? tc.surface0 : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private func keyBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(tc.tertiaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tc.surface1, in: RoundedRectangle(cornerRadius: 3))
    }

    private func highlightedTitle(_ title: String) -> AttributedString {
        FuzzyMatch.highlight(query: query, in: title)
    }

    private func moveSelection(_ delta: Int) {
        let max = min(filteredActions.count, 12) - 1
        guard max >= 0 else { return }
        lastSelectionSource = .keyboard
        selectedIndex = min(max, Swift.max(0, selectedIndex + delta))
    }

    private func executeSelected() {
        let actions = Array(filteredActions.prefix(12))
        guard selectedIndex < actions.count else { return }
        let action = actions[selectedIndex]
        guard action.isEnabled else { return }
        dismiss()
        DispatchQueue.main.async { action.run() }
    }

    private func dismiss() {
        coordinator.dismissCommandPalette()
    }

    private var filteredActions: [PaletteAction] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let actions = allActions
        guard !normalized.isEmpty else { return actions }
        return actions.filter { action in
            FuzzyMatch.matches(query: normalized, text: action.searchText)
        }.sorted { lhs, rhs in
            FuzzyMatch.score(query: normalized, text: lhs.searchText) > FuzzyMatch.score(query: normalized, text: rhs.searchText)
        }
    }

    private func shortcutLabel(_ action: ShortcutActionID) -> String? {
        ShortcutRegistry.shared.displayLabel(for: action, settings: sessionService.settings)
    }

    private var allActions: [PaletteAction] {
        let selected = sessionService.selectedSession
        let selectedID = selected?.id
        let hasWorktree = selected?.worktreePath != nil
        let canOpenClipboard = !(NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let showsVibe = sessionService.settings.appMode.showsVibeFeatures
        let niriMode = sessionService.settings.niriCanvasEnabled
        let visibleApps = NiriAppUIVisibility.commandPaletteApps(from: sessionService.registeredNiriApps)

        var actions: [PaletteAction] = [
            PaletteAction(
                id: "quick-session", icon: "plus", title: "New Quick Session",
                detail: "Create an instant terminal session",
                shortcut: shortcutLabel(.newQuickSession), searchText: "new quick session instant terminal",
                isEnabled: true, run: { _ = coordinator.performCommand(.newQuickSession) }
            ),
            PaletteAction(
                id: "repo-session", icon: "folder", title: "New Repo/Worktree Session",
                detail: "Open structured setup for repo or worktree",
                shortcut: shortcutLabel(.newRepoWorktreeSession), searchText: "new repo worktree structured session setup",
                isEnabled: true, run: { _ = coordinator.performCommand(.newRepoWorktreeSession) }
            ),
            PaletteAction(
                id: "switch-session", icon: "arrow.left.arrow.right", title: "Quick Switch Session",
                detail: "Jump to a session by name",
                shortcut: shortcutLabel(.quickSwitchSession), searchText: "switch session jump focus quick",
                isEnabled: !sessionService.sessions.isEmpty,
                run: { _ = coordinator.performCommand(.quickSwitchSession) }
            ),
            PaletteAction(
                id: "rename-session", icon: "pencil", title: "Rename Session",
                detail: "Change the title of the current session",
                shortcut: shortcutLabel(.renameSession), searchText: "rename session title",
                isEnabled: selectedID != nil,
                run: { _ = coordinator.performCommand(.renameSession) }
            ),
            PaletteAction(
                id: "close-session", icon: "xmark", title: "Close Session",
                detail: "Close the current session",
                shortcut: shortcutLabel(.closeSession), searchText: "close session",
                isEnabled: selectedID != nil,
                run: { _ = coordinator.performCommand(.closeSession) }
            ),
            PaletteAction(
                id: "relaunch-session", icon: "arrow.clockwise", title: "Relaunch Session",
                detail: "Restart the current terminal session",
                shortcut: shortcutLabel(.relaunchSession), searchText: "relaunch session restart terminal",
                isEnabled: selectedID != nil,
                run: { _ = coordinator.performCommand(.relaunchSession) }
            ),
            PaletteAction(
                id: "toggle-sidebar", icon: "sidebar.left", title: "Toggle Sidebar",
                detail: "Show or hide the sidebar",
                shortcut: shortcutLabel(.toggleSidebar), searchText: "toggle sidebar show hide",
                isEnabled: true,
                run: { _ = coordinator.performCommand(.toggleSidebar) }
            ),
            PaletteAction(
                id: "keyboard-shortcuts", icon: "keyboard", title: "Keyboard Shortcuts",
                detail: "View all keyboard shortcuts",
                shortcut: shortcutLabel(.keyboardShortcuts), searchText: "keyboard shortcuts help keys bindings",
                isEnabled: true,
                run: { _ = coordinator.performCommand(.keyboardShortcuts) }
            ),
            PaletteAction(
                id: "split-right", icon: "rectangle.split.2x1", title: niriMode ? "Niri: Add Terminal Right" : "Split Pane Right",
                detail: niriMode ? "Create a terminal tile to the right" : "Split the current pane vertically",
                shortcut: shortcutLabel(.splitRight), searchText: "split pane right vertical niri terminal",
                isEnabled: selectedID != nil,
                run: { _ = coordinator.performCommand(.splitRight) }
            ),
            PaletteAction(
                id: "split-down", icon: "rectangle.split.1x2", title: niriMode ? "Niri: Add Task Below" : "Split Pane Down",
                detail: niriMode ? "Create a terminal tile below in this task stack" : "Split the current pane horizontally",
                shortcut: shortcutLabel(.splitDown), searchText: "split pane down horizontal niri task below",
                isEnabled: selectedID != nil,
                run: { _ = coordinator.performCommand(.splitDown) }
            ),
            PaletteAction(
                id: "close-pane", icon: "xmark.rectangle", title: niriMode ? "Close Tile" : "Close Pane",
                detail: niriMode ? "Close the focused tile" : "Close the focused pane",
                shortcut: shortcutLabel(.closePane), searchText: "close pane tile split",
                isEnabled: selectedID != nil && (niriMode || sessionService.paneTrees[selectedID!] != nil),
                run: { _ = coordinator.performCommand(.closePane) }
            ),
            PaletteAction(
                id: "open-settings", icon: "gear", title: "Open Settings",
                detail: "Open IDX0 preferences",
                shortcut: shortcutLabel(.openSettings), searchText: "open settings preferences",
                isEnabled: true,
                run: { _ = coordinator.performCommand(.openSettings) }
            ),
        ]

        if niriMode {
            actions.append(contentsOf: [
                PaletteAction(
                    id: "vscode-setup-browser-debug",
                    icon: "ladybug",
                    title: "VS Code: Setup Browser Debug (idx-web)",
                    detail: "Create/update launch.json attach config and launch Chromium debug browser",
                    searchText: "vscode browser debug attach chrome launch json idx-web",
                    isEnabled: selectedID != nil,
                    run: { if let id = selectedID { _ = sessionService.setupVSCodeBrowserDebug(for: id) } }
                ),
                PaletteAction(
                    id: "niri-open-add-tile-menu", icon: "plus.circle", title: "Add Tile",
                    detail: "Open the tile spotlight to add a new tile",
                    shortcut: shortcutLabel(.niriOpenAddTileMenu), searchText: "add tile spotlight new terminal browser app plus",
                    isEnabled: selectedID != nil,
                    run: { _ = coordinator.performCommand(.niriOpenAddTileMenu) }
                ),
                PaletteAction(
                    id: "niri-overview", icon: "square.grid.3x3", title: "Niri: Toggle Overview",
                    detail: "Open or close Niri overview mode",
                    shortcut: shortcutLabel(.niriToggleOverview), searchText: "niri overview toggle canvas workspaces",
                    isEnabled: selectedID != nil,
                    run: { _ = coordinator.performCommand(.niriToggleOverview) }
                ),
                PaletteAction(
                    id: "niri-tabbed", icon: "rectangle.tophalf.inset.filled", title: "Niri: Toggle Column Tabbed Display",
                    detail: "Switch focused column between normal and tabbed",
                    shortcut: shortcutLabel(.niriToggleColumnTabbedDisplay), searchText: "niri toggle tabbed column display mode",
                    isEnabled: selectedID != nil,
                    run: { _ = coordinator.performCommand(.niriToggleColumnTabbedDisplay) }
                ),
                PaletteAction(
                    id: "niri-focused-zoom", icon: "arrow.up.left.and.arrow.down.right", title: "Niri: Toggle Focused Tile Zoom",
                    detail: "Make the focused tile fill the canvas viewport",
                    shortcut: shortcutLabel(.niriToggleFocusedTileZoom), searchText: "niri focused tile zoom fullscreen max",
                    isEnabled: selectedID != nil,
                    run: { _ = coordinator.performCommand(.niriToggleFocusedTileZoom) }
                ),
                PaletteAction(
                    id: "niri-snap", icon: "dot.scope", title: "Niri: Toggle Snap",
                    detail: sessionService.settings.niri.snapEnabled ? "Disable snap and keep free-pan release" : "Enable velocity-based snap",
                    shortcut: shortcutLabel(.niriToggleSnap), searchText: "niri snap soft snap free pan velocity",
                    isEnabled: true,
                    run: { _ = coordinator.performCommand(.niriToggleSnap) }
                ),
                PaletteAction(
                    id: "niri-focus-workspace-down", icon: "arrow.down.to.line", title: "Niri: Focus Workspace Down",
                    detail: "Move focus to the next workspace",
                    shortcut: shortcutLabel(.niriFocusWorkspaceDown), searchText: "niri workspace down focus next",
                    isEnabled: selectedID != nil,
                    run: { _ = coordinator.performCommand(.niriFocusWorkspaceDown) }
                ),
                PaletteAction(
                    id: "niri-focus-workspace-up", icon: "arrow.up.to.line", title: "Niri: Focus Workspace Up",
                    detail: "Move focus to the previous workspace",
                    shortcut: shortcutLabel(.niriFocusWorkspaceUp), searchText: "niri workspace up focus previous",
                    isEnabled: selectedID != nil,
                    run: { _ = coordinator.performCommand(.niriFocusWorkspaceUp) }
                ),
                PaletteAction(
                    id: "niri-move-column-down", icon: "arrow.down.square", title: "Niri: Move Column To Workspace Down",
                    detail: "Move focused column to the next workspace",
                    shortcut: shortcutLabel(.niriMoveColumnToWorkspaceDown),
                    searchText: "niri move column workspace down",
                    isEnabled: selectedID != nil,
                    run: { _ = coordinator.performCommand(.niriMoveColumnToWorkspaceDown) }
                ),
                PaletteAction(
                    id: "niri-move-column-up", icon: "arrow.up.square", title: "Niri: Move Column To Workspace Up",
                    detail: "Move focused column to the previous workspace",
                    shortcut: shortcutLabel(.niriMoveColumnToWorkspaceUp),
                    searchText: "niri move column workspace up",
                    isEnabled: selectedID != nil,
                    run: { _ = coordinator.performCommand(.niriMoveColumnToWorkspaceUp) }
                )
            ])

            for app in visibleApps {
                actions.append(
                    PaletteAction(
                        id: "niri-add-app-\(app.id)",
                        icon: app.icon,
                        iconImageName: app.iconImageName,
                        title: "Niri: Add \(app.displayName) Tile",
                        detail: app.menuSubtitle,
                        searchText: "niri add app \(app.displayName.lowercased()) \(app.id)",
                        isEnabled: selectedID != nil,
                        run: {
                            if let id = selectedID {
                                _ = sessionService.niriAddAppRight(in: id, appID: app.id)
                            }
                        }
                    )
                )
            }
        } else {
            actions.append(contentsOf: [
                PaletteAction(
                    id: "toggle-browser", icon: "rectangle.split.2x1", title: "Toggle Browser Split",
                    detail: "Show or hide the embedded browser pane",
                    shortcut: shortcutLabel(.toggleBrowserSplit), searchText: "toggle browser split pane",
                    isEnabled: selectedID != nil,
                    run: { _ = coordinator.performCommand(.toggleBrowserSplit) }
                ),
                PaletteAction(
                    id: "toggle-focus", icon: "eye", title: "Toggle Focus Mode",
                    detail: "Hide sidebar and workflow rail",
                    shortcut: shortcutLabel(.toggleFocusMode), searchText: "toggle focus mode distraction free",
                    isEnabled: true,
                    run: { _ = coordinator.performCommand(.toggleFocusMode) }
                ),
                PaletteAction(
                    id: "open-clipboard", icon: "link", title: "Open Clipboard URL",
                    detail: "Open clipboard URL in browser split",
                    shortcut: shortcutLabel(.openClipboardURL), searchText: "open clipboard url browser split",
                    isEnabled: selectedID != nil && canOpenClipboard,
                    run: { _ = coordinator.performCommand(.openClipboardURL) }
                ),
                PaletteAction(
                    id: "next-pane", icon: "arrow.right.square", title: "Next Pane",
                    detail: "Focus the next pane",
                    shortcut: shortcutLabel(.nextPane), searchText: "next pane focus cycle",
                    isEnabled: selectedID != nil && sessionService.paneTrees[selectedID!] != nil,
                    run: { _ = coordinator.performCommand(.nextPane) }
                )
            ])
        }

        // Session list for quick switching
        for session in sessionService.sessions where session.id != selectedID {
            actions.append(PaletteAction(
                id: "switch-\(session.id.uuidString)",
                icon: session.isWorktreeBacked ? "arrow.triangle.branch" : "terminal",
                title: "Switch to: \(session.title)",
                detail: session.subtitle,
                shortcut: nil,
                searchText: "switch \(session.title.lowercased()) \(session.subtitle.lowercased())",
                isEnabled: true,
                run: { [id = session.id] in sessionService.focusSession(id) }
            ))
        }

        if showsVibe {
            actions.append(contentsOf: [
                PaletteAction(
                    id: "create-checkpoint", icon: "bookmark", title: "Create Checkpoint",
                    detail: "Save current state of selected session",
                    shortcut: shortcutLabel(.showCheckpoints), searchText: "create checkpoint save state",
                    isEnabled: selectedID != nil,
                    run: {
                        guard let id = selectedID else { return }
                        Task { _ = try? await workflowService.createManualCheckpoint(sessionID: id, title: "Manual Checkpoint", summary: "Created from command palette", requestReview: false) }
                    }
                ),
                PaletteAction(
                    id: "toggle-rail", icon: "tray.full", title: "Toggle Workflow Rail",
                    detail: "Show or hide the supervision panel",
                    shortcut: shortcutLabel(.toggleWorkflowRail), searchText: "toggle workflow rail inbox supervision panel",
                    isEnabled: true,
                    run: { _ = coordinator.performCommand(.toggleWorkflowRail) }
                ),
                PaletteAction(
                    id: "focus-queue", icon: "exclamationmark.circle", title: "Focus Next Queue Item",
                    detail: "Jump to the highest-priority unresolved item",
                    shortcut: shortcutLabel(.focusNextQueueItem), searchText: "focus queue next item priority",
                    isEnabled: !workflowService.unresolvedQueueItems.isEmpty,
                    run: { _ = coordinator.performCommand(.focusNextQueueItem) }
                ),
                PaletteAction(
                    id: "reveal-worktree", icon: "folder.badge.questionmark", title: "Reveal Worktree in Finder",
                    detail: "Open worktree directory in Finder",
                    searchText: "reveal worktree finder",
                    isEnabled: selectedID != nil && hasWorktree,
                    run: { if let id = selectedID { sessionService.revealWorktree(for: id) } }
                ),
            ])
        }

        return actions
    }
}

struct PaletteAction: Identifiable {
    let id: String
    let icon: String
    var iconImageName: String? = nil
    let title: String
    let detail: String
    var shortcut: String? = nil
    let searchText: String
    let isEnabled: Bool
    let run: () -> Void
}
