import AppKit
import Foundation

extension AppCoordinator {
    func performCommand(_ action: ShortcutActionID) -> Bool {
        shortcutCommandDispatcher.perform(action, coordinator: self)
    }

    /// Actions that the onboarding overlay intercepts so the real canvas is not affected.
    private static let onboardingInterceptedActions: Set<ShortcutActionID> = [
        .niriAddTerminalRight, .niriAddTaskBelow, .niriAddBrowserTile, .niriOpenAddTileMenu,
        .niriFocusLeft, .niriFocusDown, .niriFocusUp, .niriFocusRight,
        .niriToggleOverview, .niriConfirmSelection, .niriToggleColumnTabbedDisplay,
        .niriToggleSnap, .niriFocusWorkspaceUp, .niriFocusWorkspaceDown,
        .niriMoveColumnToWorkspaceUp, .niriMoveColumnToWorkspaceDown,
        .niriToggleFocusedTileZoom,
        .splitRight, .splitDown, .closePane, .nextPane, .previousPane,
    ]

    func performShortcutAction(_ action: ShortcutActionID) -> Bool {
        // While the onboarding walkthrough is active, intercept canvas actions
        // so only the dummy practice canvas responds, not the real one.
        if showingNiriOnboarding, Self.onboardingInterceptedActions.contains(action) {
            postOnboardingAction(action)
            return true
        }

        let selectedSessionID = sessionService.selectedSessionID
        let niriEnabled = sessionService.settings.niriCanvasEnabled

        if let niriResult = handleNiriShortcutAction(
            action,
            selectedSessionID: selectedSessionID,
            niriEnabled: niriEnabled
        ) {
            return niriResult
        }
        if let paneResult = handlePaneAndTabShortcutAction(
            action,
            selectedSessionID: selectedSessionID,
            niriEnabled: niriEnabled
        ) {
            return paneResult
        }

        switch action {
        case .newSession:
            triggerPrimaryNewSessionAction()
            return true
        case .newQuickSession:
            sessionService.createQuickSession()
            return true
        case .newRepoWorktreeSession:
            presentNewSessionSheet(preset: .repo)
            return true
        case .newWorktreeSession:
            presentNewSessionSheet(preset: .worktree)
            return true
        case .quickSwitchSession:
            showingQuickSwitch = true
            return true
        case .focusNextSession:
            sessionService.focusNextSession()
            return true
        case .focusPreviousSession:
            sessionService.focusPreviousSession()
            return true
        case .renameSession:
            guard let selectedSessionID,
                  let session = sessionService.sessions.first(where: { $0.id == selectedSessionID }) else {
                return false
            }
            presentRenameSessionSheet(session: session)
            return true
        case .closeSession:
            guard let selectedSessionID else { return false }
            sessionService.closeSession(selectedSessionID)
            return true
        case .relaunchSession:
            guard let selectedSessionID else { return false }
            sessionService.relaunchSession(selectedSessionID)
            return true
        case .commandPalette:
            // In Niri mode, Cmd+K opens the unified tile spotlight instead
            if sessionService.settings.niriCanvasEnabled,
               let sessionID = sessionService.selectedSessionID {
                niriQuickAddRequestSessionID = sessionID
                return true
            }
            presentCommandPalette()
            return true
        case .keyboardShortcuts:
            showingKeyboardShortcuts = true
            return true
        case .openSettings:
            showingCommandPalette = false
            showingQuickSwitch = false
            showingSettings = true
            return true
        case .toggleSidebar:
            sessionService.saveSettings { $0.sidebarVisible.toggle() }
            return true
        case .toggleWorkflowRail:
            sessionService.saveSettings { $0.inboxVisible.toggle() }
            return true
        case .toggleFocusMode:
            workflowService.toggleFocusMode()
            return true
        case .focusNextQueueItem:
            guard let item = workflowService.unresolvedQueueItems.first else { return false }
            sessionService.focusSession(item.sessionID)
            return true
        case .showDiff:
            showingDiffOverlay.toggle()
            return true
        case .showCheckpoints:
            showingCheckpoints.toggle()
            return true
        case .quickApprove:
            return quickApproveSelectedSession()
        case .openClipboardURL, .newTab, .nextTab, .previousTab, .closeTab,
             .splitRight, .splitDown, .closePane, .nextPane, .previousPane, .toggleBrowserSplit:
            return false
        case .niriAddTerminalRight, .niriAddTaskBelow, .niriAddBrowserTile, .niriOpenAddTileMenu,
             .niriFocusLeft, .niriFocusDown, .niriFocusUp, .niriFocusRight,
             .niriToggleOverview, .niriConfirmSelection, .niriToggleColumnTabbedDisplay,
             .niriToggleSnap, .niriFocusWorkspaceUp, .niriFocusWorkspaceDown,
             .niriMoveColumnToWorkspaceUp, .niriMoveColumnToWorkspaceDown,
             .niriToggleFocusedTileZoom,
             .niriZoomInFocusedWebTile, .niriZoomOutFocusedWebTile:
            return false
        }
    }

    func handlePaneAndTabShortcutAction(
        _ action: ShortcutActionID,
        selectedSessionID: UUID?,
        niriEnabled: Bool
    ) -> Bool? {
        switch action {
        case .openClipboardURL:
            return sessionService.requestOpenClipboardURLInSplit(for: selectedSessionID)
        case .newTab:
            guard let selectedSessionID else { return false }
            _ = sessionService.createTab(in: selectedSessionID)
            return true
        case .nextTab:
            guard let selectedSessionID else { return false }
            sessionService.focusNextTab(in: selectedSessionID)
            return true
        case .previousTab:
            guard let selectedSessionID else { return false }
            sessionService.focusPreviousTab(in: selectedSessionID)
            return true
        case .closeTab:
            guard let selectedSessionID else { return false }
            sessionService.closeActiveTab(in: selectedSessionID)
            return true
        case .splitRight:
            guard let selectedSessionID else { return false }
            if niriEnabled {
                _ = sessionService.niriAddTerminalRight(in: selectedSessionID)
            } else {
                sessionService.splitPane(sessionID: selectedSessionID, direction: .vertical)
            }
            postOnboardingAction(action)
            return true
        case .splitDown:
            guard let selectedSessionID else { return false }
            if niriEnabled {
                _ = sessionService.niriAddTaskBelow(in: selectedSessionID)
            } else {
                sessionService.splitPane(sessionID: selectedSessionID, direction: .horizontal)
            }
            postOnboardingAction(action)
            return true
        case .closePane:
            guard let selectedSessionID else { return false }
            if niriEnabled {
                sessionService.closeNiriFocusedItem(in: selectedSessionID)
            } else {
                sessionService.closePane(sessionID: selectedSessionID)
            }
            postOnboardingAction(action)
            return true
        case .nextPane:
            guard let selectedSessionID else { return false }
            sessionService.focusNextPane(sessionID: selectedSessionID)
            return true
        case .previousPane:
            guard let selectedSessionID else { return false }
            sessionService.focusPreviousPane(sessionID: selectedSessionID)
            return true
        case .toggleBrowserSplit:
            guard let selectedSessionID else { return false }
            sessionService.requestToggleBrowserSplit(for: selectedSessionID)
            return true
        default:
            return nil
        }
    }

    private func postOnboardingAction(_ action: ShortcutActionID) {
        NotificationCenter.default.post(
            name: .niriOnboardingActionPerformed,
            object: nil,
            userInfo: ["action": action.rawValue]
        )
    }

    func handleNiriShortcutAction(
        _ action: ShortcutActionID,
        selectedSessionID: UUID?,
        niriEnabled: Bool
    ) -> Bool? {
        switch action {
        case .niriAddTerminalRight:
            guard niriEnabled, let selectedSessionID else { return false }
            _ = sessionService.niriAddTerminalRight(in: selectedSessionID)
            postOnboardingAction(action)
            return true
        case .niriAddTaskBelow:
            guard niriEnabled, let selectedSessionID else { return false }
            _ = sessionService.niriAddTaskBelow(in: selectedSessionID)
            postOnboardingAction(action)
            return true
        case .niriAddBrowserTile:
            guard niriEnabled, let selectedSessionID else { return false }
            _ = sessionService.requestAddNiriBrowserTile(in: selectedSessionID)
            return true
        case .niriOpenAddTileMenu:
            return requestNiriAddTileMenu(for: selectedSessionID)
        case .niriFocusLeft:
            guard niriEnabled, let selectedSessionID else { return false }
            sessionService.niriFocusNeighbor(sessionID: selectedSessionID, horizontal: -1)
            postOnboardingAction(action)
            return true
        case .niriFocusDown:
            guard niriEnabled, let selectedSessionID else { return false }
            sessionService.niriFocusNeighbor(sessionID: selectedSessionID, vertical: 1)
            postOnboardingAction(action)
            return true
        case .niriFocusUp:
            guard niriEnabled, let selectedSessionID else { return false }
            sessionService.niriFocusNeighbor(sessionID: selectedSessionID, vertical: -1)
            postOnboardingAction(action)
            return true
        case .niriFocusRight:
            guard niriEnabled, let selectedSessionID else { return false }
            sessionService.niriFocusNeighbor(sessionID: selectedSessionID, horizontal: 1)
            postOnboardingAction(action)
            return true
        case .niriToggleOverview:
            guard niriEnabled, let selectedSessionID else { return false }
            sessionService.toggleNiriOverview(sessionID: selectedSessionID)
            postOnboardingAction(action)
            return true
        case .niriConfirmSelection:
            guard niriEnabled, let selectedSessionID else { return false }
            let layout = sessionService.niriLayout(for: selectedSessionID)
            guard layout.isOverviewOpen else { return false }
            sessionService.toggleNiriOverview(sessionID: selectedSessionID)
            return true
        case .niriToggleColumnTabbedDisplay:
            guard niriEnabled, let selectedSessionID else { return false }
            sessionService.toggleNiriColumnTabbedDisplay(sessionID: selectedSessionID)
            return true
        case .niriToggleSnap:
            guard niriEnabled else { return false }
            sessionService.saveSettings { $0.niri.snapEnabled.toggle() }
            return true
        case .niriFocusWorkspaceUp:
            guard niriEnabled, let selectedSessionID else { return false }
            sessionService.focusNiriWorkspaceUp(sessionID: selectedSessionID)
            return true
        case .niriFocusWorkspaceDown:
            guard niriEnabled, let selectedSessionID else { return false }
            sessionService.focusNiriWorkspaceDown(sessionID: selectedSessionID)
            return true
        case .niriMoveColumnToWorkspaceUp:
            guard niriEnabled, let selectedSessionID else { return false }
            sessionService.moveNiriColumnToWorkspaceUp(sessionID: selectedSessionID)
            return true
        case .niriMoveColumnToWorkspaceDown:
            guard niriEnabled, let selectedSessionID else { return false }
            sessionService.moveNiriColumnToWorkspaceDown(sessionID: selectedSessionID)
            return true
        case .niriToggleFocusedTileZoom:
            guard niriEnabled, let selectedSessionID else { return false }
            return sessionService.toggleNiriFocusedTileZoom(sessionID: selectedSessionID)
        case .niriZoomInFocusedWebTile:
            guard niriEnabled, let selectedSessionID else { return false }
            return sessionService.adjustNiriFocusedWebTileZoom(for: selectedSessionID, delta: 0.1)
        case .niriZoomOutFocusedWebTile:
            guard niriEnabled, let selectedSessionID else { return false }
            return sessionService.adjustNiriFocusedWebTileZoom(for: selectedSessionID, delta: -0.1)
        default:
            return nil
        }
    }

    func fetchDiffStats(for sessionID: UUID) {
        guard let session = sessionService.sessions.first(where: { $0.id == sessionID }) else { return }
        let path = session.worktreePath ?? session.repoPath
        guard let path else { return }
        Task {
            let git = GitService()
            if let stat = try? await git.diffStat(path: path) {
                sessionService.setDiffStat(for: sessionID, stat: stat)
            }
        }
    }

    func presentNewSessionSheet(preset: NewSessionPreset) {
        newSessionPreset = preset
        showingNewSessionSheet = true
    }

    func presentCommandPalette() {
        showingCommandPalette = true
    }

    func dismissCommandPalette() {
        showingCommandPalette = false
    }

    func presentNiriOnboardingNow() {
        showingNiriOnboarding = true
    }

    @discardableResult
    func requestNiriAddTileMenu(for sessionID: UUID?) -> Bool {
        guard sessionService.settings.niriCanvasEnabled,
              let sessionID else {
            return false
        }
        niriQuickAddRequestSessionID = sessionID
        return true
    }

    func triggerPrimaryNewSessionAction() {
        // In Niri mode, Cmd+N should add a new right-side tile in the current session.
        if triggerNiriPrimaryNewTileAction() {
            return
        }

        // Non-Niri fallback: create a fresh session.
        triggerDefaultVibeNewSessionAction()
    }

    @discardableResult
    func triggerNiriPrimaryNewTileAction() -> Bool {
        guard sessionService.settings.niriCanvasEnabled,
              let sessionID = sessionService.selectedSessionID else {
            return false
        }

        guard sessionService.niriAddTerminalRight(in: sessionID) != nil else {
            return false
        }

        // In Niri mode, Cmd+N should open the default vibe tool in the new tile
        // when one is configured, regardless of the global auto-launch toggle.
        workflowService.launchDefaultToolIfConfigured(
            in: sessionID,
            settings: sessionService.settings,
            respectToggle: false
        )
        return true
    }

    @discardableResult
    func quickApproveSelectedSession() -> Bool {
        guard let selectedID = sessionService.selectedSessionID else {
            return false
        }
        guard let result = terminalMonitor.agentStates[selectedID],
              result.hasDetectedAgent,
              result.isApprovalPrompt else {
            return false
        }

        let response: String
        switch result.detectedAgent {
        case .codex:
            response = "yes\n"
        default:
            response = "y\n"
        }
        sessionService.ensureController(for: selectedID)?.send(text: response)
        return true
    }

    func triggerSidebarNewTerminalAction() {
        Task { @MainActor in
            do {
                let currentCwd = sessionService.selectedSession?.lastKnownCwd
                    ?? sessionService.selectedSession?.repoPath
                _ = try await sessionService.createSession(
                    from: SessionCreationRequest(
                        title: nil,
                        repoPath: currentCwd,
                        createWorktree: false,
                        branchName: nil,
                        existingWorktreePath: nil,
                        shellPath: nil,
                        launchToolID: nil
                    )
                )
            } catch {
                Logger.error("Sidebar new terminal failed: \(error.localizedDescription)")
            }
        }
    }

    func triggerOpenFolderSession() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder to open as a new session"

        guard panel.runModal() == .OK, let folder = panel.url?.path else { return }

        Task { @MainActor in
            do {
                _ = try await sessionService.createSession(
                    from: SessionCreationRequest(
                        title: nil,
                        repoPath: folder,
                        createWorktree: false,
                        branchName: nil,
                        existingWorktreePath: nil,
                        shellPath: nil,
                        launchToolID: nil
                    )
                )
            } catch {
                Logger.error("Open folder session failed: \(error.localizedDescription)")
            }
        }
    }

    func triggerDefaultVibeNewSessionAction() {
        Task { @MainActor in
            do {
                // Inherit the current session's working directory so the new tab starts in the same place
                let currentCwd = sessionService.selectedSession?.lastKnownCwd
                    ?? sessionService.selectedSession?.repoPath
                let request = SessionCreationRequest(
                    title: nil,
                    repoPath: currentCwd,
                    createWorktree: false,
                    branchName: nil,
                    existingWorktreePath: nil,
                    shellPath: nil,
                    sandboxProfile: nil,
                    networkPolicy: nil,
                    launchToolID: sessionService.settings.autoLaunchDefaultVibeToolOnCmdN
                        ? sessionService.settings.defaultVibeToolID
                        : nil
                )
                let result = try await sessionService.createSession(from: request)
                workflowService.launchDefaultToolIfConfigured(in: result.session.id, settings: sessionService.settings)
            } catch {
                Logger.error("Default new session failed: \(error.localizedDescription)")
            }
        }
    }

}
