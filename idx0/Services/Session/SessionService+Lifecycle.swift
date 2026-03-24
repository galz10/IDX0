import AppKit
import Foundation
import SwiftUI

extension SessionService {
    func createQuickSession(atPath path: String? = nil, title: String? = nil) {
        Task {
            do {
                let created = try await createSession(
                    from: SessionCreationRequest(
                        title: title,
                        repoPath: nil,
                        createWorktree: false,
                        branchName: nil,
                        existingWorktreePath: nil,
                        shellPath: nil
                    )
                )
                if let normalizedPath = normalizePath(path) {
                    applyLaunchDirectory(normalizedPath, to: created.session.id)
                }
            } catch {
                Logger.error("Failed creating quick session: \(error.localizedDescription)")
            }
        }
    }

    func createQuickSession() {
        createQuickSession(atPath: nil, title: nil)
    }

    func createSession(from request: SessionCreationRequest) async throws -> SessionCreationResult {
        let normalizedRepo = normalizeRepoPath(request.repoPath)
        let resolvedShell = try shellHealthService.resolvedShell(
            explicitShell: request.shellPath,
            preferredShell: settings.preferredShellPath
        )

        var repoPath: String?
        var branchName: String?
        var worktreePath: String?
        var isWorktreeBacked = false
        var createdWorktree: WorktreeInfo?

        if let normalizedRepo {
            branchName = request.branchName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if branchName?.isEmpty == true { branchName = nil }

            if request.createWorktree {
                let repoInfo = try await worktreeService.validateRepo(path: normalizedRepo)
                repoPath = repoInfo.topLevelPath
                let worktree: WorktreeInfo
                if let existingWorktreePath = normalizePath(request.existingWorktreePath) {
                    worktree = try await worktreeService.attachExistingWorktree(
                        repoPath: repoInfo.topLevelPath,
                        worktreePath: existingWorktreePath
                    )
                } else {
                    worktree = try await worktreeService.createWorktree(
                        repoPath: repoInfo.topLevelPath,
                        branchName: branchName,
                        sessionTitle: request.title
                    )
                }
                worktreePath = worktree.worktreePath
                branchName = worktree.branchName
                isWorktreeBacked = true
                createdWorktree = worktree
            } else {
                if let repoInfo = try? await worktreeService.validateRepo(path: normalizedRepo) {
                    repoPath = repoInfo.topLevelPath
                    if branchName == nil {
                        branchName = repoInfo.currentBranch
                    }
                } else {
                    repoPath = normalizedRepo
                }
            }
        }

        let now = Date()
        let resolvedTitle = resolveSessionTitle(
            requested: request.title,
            repoPath: repoPath,
            branchName: branchName
        )

        let sandboxProfile = request.sandboxProfile ?? settings.defaultSandboxProfile
        let enforcementState: SandboxEnforcementState = .unenforced
        let networkPolicy = request.networkPolicy ?? settings.defaultNetworkPolicy
        let sessionID = UUID()

        let session = Session(
            id: sessionID,
            title: resolvedTitle,
            hasCustomTitle: !(request.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            isPinned: false,
            createdAt: now,
            lastActiveAt: now,
            repoPath: repoPath,
            branchName: branchName,
            worktreePath: worktreePath,
            worktreeState: isWorktreeBacked ? .attached : nil,
            isWorktreeBacked: isWorktreeBacked,
            shellPath: resolvedShell,
            lastLaunchCwd: worktreePath ?? repoPath,
            attentionState: .normal,
            latestAttentionReason: nil,
            sandboxProfile: sandboxProfile,
            sandboxEnforcementState: enforcementState,
            networkPolicy: networkPolicy,
            statusText: nil,
            lastKnownCwd: worktreePath ?? repoPath,
            browserState: nil,
            lastLaunchManifest: SessionLaunchManifest(
                sessionID: sessionID,
                cwd: normalizePath(worktreePath ?? repoPath ?? FileManager.default.homeDirectoryForCurrentUser.path)
                    ?? FileManager.default.homeDirectoryForCurrentUser.path,
                shellPath: resolvedShell,
                repoPath: normalizePath(repoPath),
                worktreePath: normalizePath(worktreePath),
                sandboxProfile: sandboxProfile,
                networkPolicy: networkPolicy,
                tempRoot: sandboxProfile == .worktreeAndTemp ? defaultTempRoot(for: sessionID) : nil,
                environment: [:],
                projectID: nil,
                ipcSocketPath: ipcSocketPath
            ),
            selectedVibeToolID: request.launchToolID
        )

        sessions.append(session)
        ensureTabState(for: session.id, defaultRootControllerID: session.id)
        synchronizeProjectGroups()
        selectSession(session.id)
        persistSoon()
        onSessionCreated?(session)

        return SessionCreationResult(session: session, worktree: createdWorktree)
    }

    func selectSession(_ id: UUID) {
        selectSession(id, updatesRecency: true)
    }

    func focusSession(_ id: UUID) {
        selectSession(id, updatesRecency: false)
    }

    func selectSession(_ id: UUID, updatesRecency: Bool) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        let previousSelectedSessionID = selectedSessionID
        selectedSessionID = id
        if let previousSelectedSessionID, previousSelectedSessionID != id {
            controllerBecameHidden(sessionID: previousSelectedSessionID)
        }
        if updatesRecency {
            updateLastActive(id, at: Date())
        }
        resolveAttentionOnVisit(sessionID: id)
        onSessionFocused?(id)
        reconcileActiveState()
        persistSoon()

        let browserVisible = sessions.first(where: { $0.id == id })?.browserState?.isVisible == true
        let shouldPreferBrowserFocus = browserVisible && lastFocusedSurfaceBySession[id] == .browser
        let terminalController = ensureController(for: id)
        let launchedTerminalControllerIDs: Set<UUID> = settings.niriCanvasEnabled
            ? launchFocusedNiriTerminalIfVisible(sessionID: id, reason: .selectedSessionVisible)
            : requestLaunchForActiveTerminals(in: id, reason: .selectedSessionVisible)
        let shouldFocusTerminal = !settings.niriCanvasEnabled || !launchedTerminalControllerIDs.isEmpty

        if shouldPreferBrowserFocus {
            _ = browserController(for: id)
        } else if shouldFocusTerminal {
            terminalController?.focus()
            setLastFocusedSurface(for: id, surface: .terminal)
            if browserVisible {
                _ = browserController(for: id)
            }
        }
    }

    func renameSession(_ id: UUID, title: String) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        guard let index = indexOfSession(id) else { return }
        sessions[index].title = cleaned
        sessions[index].hasCustomTitle = true
        synchronizeProjectGroups()
        persistSoon()
    }

    func setPinned(_ id: UUID, pinned: Bool) {
        guard let index = indexOfSession(id) else { return }
        guard sessions[index].isPinned != pinned else { return }
        sessions[index].isPinned = pinned
        persistSoon()
    }

    func togglePinned(_ id: UUID) {
        guard let index = indexOfSession(id) else { return }
        setPinned(id, pinned: !sessions[index].isPinned)
    }

    func moveSessions(from source: IndexSet, to destination: Int) {
        sessions.move(fromOffsets: source, toOffset: destination)
        synchronizeProjectGroups()
        persistSoon()
    }

    func moveProjectGroups(from source: IndexSet, to destination: Int) {
        projectService.moveGroups(from: source, to: destination)
        projectGroups = projectService.groups
        persistSoon()
    }

    func toggleProjectCollapsed(_ groupID: UUID) {
        projectService.toggleCollapsed(groupID)
        projectGroups = projectService.groups
        persistSoon()
    }

    /// Focus the most recently active session in the Nth project group (1-based).
    func focusProjectGroup(at index: Int) {
        let sections = projectSections
        guard index >= 1, index <= sections.count else { return }
        let section = sections[index - 1]
        // Pick the most recently active session in this group
        if let best = section.sessions.max(by: { $0.lastActiveAt < $1.lastActiveAt }) {
            focusSession(best.id)
        }
    }

    /// Focus the next session (by flat order). Wraps around.
    func focusNextSession() {
        guard !sessions.isEmpty else { return }
        guard let currentID = selectedSessionID,
              let currentIndex = sessions.firstIndex(where: { $0.id == currentID }) else {
            focusSession(sessions[0].id)
            return
        }
        let nextIndex = (currentIndex + 1) % sessions.count
        focusSession(sessions[nextIndex].id)
    }

    /// Focus the previous session (by flat order). Wraps around.
    func focusPreviousSession() {
        guard !sessions.isEmpty else { return }
        guard let currentID = selectedSessionID,
              let currentIndex = sessions.firstIndex(where: { $0.id == currentID }) else {
            focusSession(sessions[0].id)
            return
        }
        let prevIndex = (currentIndex - 1 + sessions.count) % sessions.count
        focusSession(sessions[prevIndex].id)
    }

    // MARK: - Tabs

    func tabs(for sessionID: UUID) -> [SessionTerminalTabItem] {
        let tabs = tabsBySession[sessionID] ?? []
        return tabs.map {
            SessionTerminalTabItem(id: $0.id, title: $0.title, paneCount: $0.paneCount)
        }
    }

    func selectedTabID(for sessionID: UUID) -> UUID? {
        selectedTabIDBySession[sessionID] ?? tabsBySession[sessionID]?.first?.id
    }

    func tabState(sessionID: UUID, tabID: UUID) -> SessionTerminalTab? {
        tabsBySession[sessionID]?.first(where: { $0.id == tabID })
    }

    @discardableResult
    func createTab(in sessionID: UUID, activate: Bool = true) -> UUID? {
        guard sessions.contains(where: { $0.id == sessionID }) else { return nil }
        ensureTabState(for: sessionID, defaultRootControllerID: sessionID)
        var tabs = tabsBySession[sessionID, default: []]
        let tab = SessionTerminalTab(
            id: UUID(),
            title: nextTabTitle(for: tabs),
            rootControllerID: UUID(),
            paneTree: nil,
            focusedPaneControllerID: nil
        )
        tabs.append(tab)
        tabsBySession[sessionID] = tabs
        if activate {
            selectedTabIDBySession[sessionID] = tab.id
            syncActivePaneState(for: sessionID)
            if shouldLaunchVisibleTerminals(for: sessionID) {
                _ = requestLaunchForActiveTerminals(in: sessionID, reason: .activeSplitPaneVisible)
            }
            ensureController(for: sessionID)?.focus()
            setLastFocusedSurface(for: sessionID, surface: .terminal)
        }
        return tab.id
    }

    func closeActiveTab(in sessionID: UUID) {
        ensureTabState(for: sessionID, defaultRootControllerID: sessionID)
        var tabs = tabsBySession[sessionID, default: []]
        guard tabs.count > 1 else { return }
        guard let activeIndex = activeTabIndex(for: sessionID) else { return }

        let closingTab = tabs[activeIndex]
        for controllerID in Set(closingTab.allControllerIDs) {
            runtimeControllers[controllerID]?.terminate()
            runtimeControllers.removeValue(forKey: controllerID)
            ownerSessionIDByControllerID.removeValue(forKey: controllerID)
            clearLaunchTracking(for: controllerID)
        }

        tabs.remove(at: activeIndex)
        tabsBySession[sessionID] = tabs
        let nextIndex = min(activeIndex, tabs.count - 1)
        selectedTabIDBySession[sessionID] = tabs[nextIndex].id
        removeNiriCells(sessionID: sessionID, matchingTabID: closingTab.id)
        syncNiriFocusWithSelectedTab(sessionID: sessionID)
        syncActivePaneState(for: sessionID)
        if shouldLaunchVisibleTerminals(for: sessionID) {
            _ = requestLaunchForActiveTerminals(in: sessionID, reason: .activeSplitPaneVisible)
        }
        if selectedSessionID == sessionID {
            ensureController(for: sessionID)?.focus()
        }
    }

    func focusNextTab(in sessionID: UUID) {
        ensureTabState(for: sessionID, defaultRootControllerID: sessionID)
        guard let tabs = tabsBySession[sessionID], tabs.count > 1 else { return }
        guard let selected = selectedTabIDBySession[sessionID],
              let currentIndex = tabs.firstIndex(where: { $0.id == selected }) else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
        selectedTabIDBySession[sessionID] = tabs[nextIndex].id
        syncNiriFocusWithSelectedTab(sessionID: sessionID)
        syncActivePaneState(for: sessionID)
        if shouldLaunchVisibleTerminals(for: sessionID) {
            _ = requestLaunchForActiveTerminals(in: sessionID, reason: .activeSplitPaneVisible)
        }
        if selectedSessionID == sessionID {
            ensureController(for: sessionID)?.focus()
        }
    }

    func focusPreviousTab(in sessionID: UUID) {
        ensureTabState(for: sessionID, defaultRootControllerID: sessionID)
        guard let tabs = tabsBySession[sessionID], tabs.count > 1 else { return }
        guard let selected = selectedTabIDBySession[sessionID],
              let currentIndex = tabs.firstIndex(where: { $0.id == selected }) else { return }
        let previousIndex = (currentIndex - 1 + tabs.count) % tabs.count
        selectedTabIDBySession[sessionID] = tabs[previousIndex].id
        syncNiriFocusWithSelectedTab(sessionID: sessionID)
        syncActivePaneState(for: sessionID)
        if shouldLaunchVisibleTerminals(for: sessionID) {
            _ = requestLaunchForActiveTerminals(in: sessionID, reason: .activeSplitPaneVisible)
        }
        if selectedSessionID == sessionID {
            ensureController(for: sessionID)?.focus()
        }
    }

    func selectTab(sessionID: UUID, tabID: UUID) {
        ensureTabState(for: sessionID, defaultRootControllerID: sessionID)
        guard let tabs = tabsBySession[sessionID], tabs.contains(where: { $0.id == tabID }) else { return }
        selectedTabIDBySession[sessionID] = tabID
        syncNiriFocusWithSelectedTab(sessionID: sessionID)
        syncActivePaneState(for: sessionID)
        if shouldLaunchVisibleTerminals(for: sessionID) {
            _ = requestLaunchForActiveTerminals(in: sessionID, reason: .activeSplitPaneVisible)
        }
        if selectedSessionID == sessionID {
            ensureController(for: sessionID)?.focus()
        }
    }

    // MARK: - Split Panes

    /// Split the currently focused pane in the active tab for a session.
    func splitPane(sessionID: UUID, direction: PaneSplitDirection) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        ensureTabState(for: sessionID, defaultRootControllerID: sessionID)
        guard var tabs = tabsBySession[sessionID], let activeIndex = activeTabIndex(for: sessionID) else { return }
        var tab = tabs[activeIndex]

        // Ensure the active root controller exists before we build a split tree.
        _ = ensureController(forControllerID: tab.rootControllerID, ownerSessionID: sessionID)

        // Resolve shell and cwd for the new pane without touching the session's manifest
        let shellPath = session.shellPath
        let launchDir = session.lastKnownCwd
            ?? session.worktreePath
            ?? session.repoPath
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        // Create a new controller for the new pane
        let newControllerID = UUID()
        let newController = TerminalSessionController(
            sessionID: newControllerID,
            launchDirectory: launchDir,
            shellPath: shellPath,
            host: host
        )
        queueTerminalStartupCommandIfNeeded(
            controller: newController,
            ownerSessionID: sessionID,
            launchDirectory: launchDir
        )
        wireControllerCallbacks(newController, sessionID: sessionID)
        runtimeControllers[newControllerID] = newController
        ownerSessionIDByControllerID[newControllerID] = sessionID

        if let existingTree = tab.paneTree {
            let focusedID = tab.focusedPaneControllerID ?? existingTree.terminalControllerIDs.first ?? tab.rootControllerID
            tab.paneTree = existingTree.splitting(
                controllerID: focusedID,
                direction: direction,
                newControllerID: newControllerID
            )
        } else {
            let singlePane = PaneNode.terminal(id: UUID(), controllerID: tab.rootControllerID)
            let newPane = PaneNode.terminal(id: UUID(), controllerID: newControllerID)
            tab.paneTree = .split(
                id: UUID(),
                direction: direction,
                first: singlePane,
                second: newPane,
                fraction: 0.5
            )
        }

        tab.focusedPaneControllerID = newControllerID
        tabs[activeIndex] = tab
        tabsBySession[sessionID] = tabs
        syncActivePaneState(for: sessionID)
        if shouldLaunchVisibleTerminals(for: sessionID) {
            _ = requestLaunchForActiveTerminals(in: sessionID, reason: .activeSplitPaneVisible)
        }
    }

    /// Close the currently focused pane in the active tab for a session.
    /// If only one pane remains, no-op (option 1 behavior).
    func closePane(sessionID: UUID) {
        ensureTabState(for: sessionID, defaultRootControllerID: sessionID)
        guard var tabs = tabsBySession[sessionID], let activeIndex = activeTabIndex(for: sessionID) else { return }
        var tab = tabs[activeIndex]
        guard let tree = tab.paneTree else { return }
        let focusedID = tab.focusedPaneControllerID ?? tree.terminalControllerIDs.first ?? tab.rootControllerID

        // Don't close if it's the last pane.
        guard tree.terminalCount > 1 else { return }

        runtimeControllers[focusedID]?.terminate()
        runtimeControllers.removeValue(forKey: focusedID)
        ownerSessionIDByControllerID.removeValue(forKey: focusedID)
        clearLaunchTracking(for: focusedID)

        if let remaining = tree.removing(controllerID: focusedID) {
            if remaining.terminalCount == 1 {
                let remainingControllerID = remaining.terminalControllerIDs.first ?? tab.rootControllerID
                tab.rootControllerID = remainingControllerID
                tab.paneTree = nil
                tab.focusedPaneControllerID = nil
            } else {
                tab.paneTree = remaining
                tab.focusedPaneControllerID = remaining.terminalControllerIDs.first
            }
        } else {
            tab.paneTree = nil
            tab.focusedPaneControllerID = nil
        }

        tabs[activeIndex] = tab
        tabsBySession[sessionID] = tabs
        syncActivePaneState(for: sessionID)
    }

    /// Cycle focus to the next pane in the active tab.
    func focusNextPane(sessionID: UUID) {
        ensureTabState(for: sessionID, defaultRootControllerID: sessionID)
        guard var tabs = tabsBySession[sessionID], let activeIndex = activeTabIndex(for: sessionID) else { return }
        var tab = tabs[activeIndex]
        guard let tree = tab.paneTree else { return }
        let ids = tree.terminalControllerIDs
        guard ids.count > 1 else { return }
        let currentID = tab.focusedPaneControllerID ?? ids.first!
        if let idx = ids.firstIndex(of: currentID) {
            let nextIdx = (idx + 1) % ids.count
            tab.focusedPaneControllerID = ids[nextIdx]
            tabs[activeIndex] = tab
            tabsBySession[sessionID] = tabs
            syncActivePaneState(for: sessionID)
            if shouldLaunchVisibleTerminals(for: sessionID) {
                _ = requestLaunch(for: ids[nextIdx], ownerSessionID: sessionID, reason: .activeSplitPaneVisible)
            }
            ensurePaneController(for: ids[nextIdx])?.focus()
        }
    }

    /// Cycle focus to the previous pane in the active tab.
    func focusPreviousPane(sessionID: UUID) {
        ensureTabState(for: sessionID, defaultRootControllerID: sessionID)
        guard var tabs = tabsBySession[sessionID], let activeIndex = activeTabIndex(for: sessionID) else { return }
        var tab = tabs[activeIndex]
        guard let tree = tab.paneTree else { return }
        let ids = tree.terminalControllerIDs
        guard ids.count > 1 else { return }
        let currentID = tab.focusedPaneControllerID ?? ids.first!
        if let idx = ids.firstIndex(of: currentID) {
            let prevIdx = (idx - 1 + ids.count) % ids.count
            tab.focusedPaneControllerID = ids[prevIdx]
            tabs[activeIndex] = tab
            tabsBySession[sessionID] = tabs
            syncActivePaneState(for: sessionID)
            if shouldLaunchVisibleTerminals(for: sessionID) {
                _ = requestLaunch(for: ids[prevIdx], ownerSessionID: sessionID, reason: .activeSplitPaneVisible)
            }
            ensurePaneController(for: ids[prevIdx])?.focus()
        }
    }

    /// Set the focused pane controller in the active tab (called from PaneTreeView tap).
    func setFocusedPane(sessionID: UUID, controllerID: UUID) {
        ensureTabState(for: sessionID, defaultRootControllerID: sessionID)
        guard var tabs = tabsBySession[sessionID], let activeIndex = activeTabIndex(for: sessionID) else { return }
        var tab = tabs[activeIndex]
        tab.focusedPaneControllerID = controllerID
        tabs[activeIndex] = tab
        tabsBySession[sessionID] = tabs
        syncActivePaneState(for: sessionID)
        if shouldLaunchVisibleTerminals(for: sessionID) {
            _ = requestLaunch(for: controllerID, ownerSessionID: sessionID, reason: .activeSplitPaneVisible)
        }
    }

    func wireControllerCallbacks(_ controller: TerminalSessionController, sessionID: UUID) {
        controller.onTitleChanged = { [weak self] title in
            guard let self else { return }
            // Only update title from the primary controller
            if controller.sessionID == sessionID {
                if let idx = self.indexOfSession(sessionID), !self.sessions[idx].hasCustomTitle {
                    self.sessions[idx].title = title
                    self.synchronizeProjectGroups()
                    self.persistSoon()
                }
            }
        }
        controller.onCwdChanged = { [weak self] cwd in
            guard let self else { return }
            if let idx = self.indexOfSession(sessionID) {
                self.sessions[idx].lastKnownCwd = cwd
                self.persistSoon()
            }
        }
    }

}
