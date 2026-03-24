import AppKit
import Foundation
import SwiftUI

extension SessionService {
    func closeSession(_ id: UUID) {
        guard let index = indexOfSession(id) else { return }
        let closingSession = sessions[index]
        let niriLayout = niriLayoutsBySession[id] ?? .empty
        let niriBrowserIDs = niriBrowserItemIDs(in: niriLayout)
        let niriAppItemsByID = niriAppItemIDsByAppID(in: niriLayout)

        let wasSelected = selectedSessionID == id
        let previousSelection = index > 0 ? sessions[index - 1].id : nil
        let nextSelection = index + 1 < sessions.count ? sessions[index + 1].id : nil

        if let tabs = tabsBySession[id] {
            for controllerID in Set(tabs.flatMap(\.allControllerIDs)) {
                runtimeControllers[controllerID]?.terminate()
                runtimeControllers.removeValue(forKey: controllerID)
                ownerSessionIDByControllerID.removeValue(forKey: controllerID)
                clearLaunchTracking(for: controllerID)
            }
        } else {
            runtimeControllers[id]?.terminate()
            runtimeControllers.removeValue(forKey: id)
            ownerSessionIDByControllerID.removeValue(forKey: id)
            clearLaunchTracking(for: id)
        }

        browserControllers.removeValue(forKey: id)
        for itemID in niriBrowserIDs {
            niriBrowserControllersByItemID.removeValue(forKey: itemID)
        }

        var appItemIDsToStopByID: [String: Set<UUID>] = [:]
        for (appID, itemIDs) in niriAppItemsByID {
            appItemIDsToStopByID[appID] = Set(itemIDs)
        }
        for (itemID, controllersByID) in niriAppControllersByItemID {
            for (appID, controller) in controllersByID where controller.sessionID == id {
                appItemIDsToStopByID[appID, default: []].insert(itemID)
            }
        }

        for (appID, itemIDs) in appItemIDsToStopByID {
            for itemID in itemIDs {
                stopNiriAppController(itemID: itemID, appID: appID)
            }
            if let descriptor = niriAppRegistry.descriptor(for: appID) {
                descriptor.cleanupSessionArtifacts?(self, id)
            }
        }
        tabsBySession.removeValue(forKey: id)
        selectedTabIDBySession.removeValue(forKey: id)
        niriLayoutsBySession.removeValue(forKey: id)
        niriFocusedTileZoomItemIDBySession.removeValue(forKey: id)
        paneTrees.removeValue(forKey: id)
        focusedPaneControllerID.removeValue(forKey: id)

        if closingSession.isWorktreeBacked,
           let worktreePath = closingSession.worktreePath {
            pendingWorktreeCleanupNotice = WorktreeCleanupNotice(
                sessionTitle: closingSession.title,
                repoPath: closingSession.repoPath,
                branchName: closingSession.branchName,
                worktreePath: worktreePath
            )
        }

        sessions.remove(at: index)
        attentionCenter.removeItems(for: id)
        attentionItems = attentionCenter.items
        lastFocusedSurfaceBySession.removeValue(forKey: id)
        wrapperFallbackAppliedBySessionID.remove(id)
        if pendingWorktreeDeletePrompt?.sessionID == id {
            pendingWorktreeDeletePrompt = nil
        }

        if wasSelected {
            selectedSessionID = previousSelection ?? nextSelection
            if let replacementID = selectedSessionID {
                _ = ensureController(for: replacementID)
            }
        }

        synchronizeProjectGroups()
        synchronizeAttentionState()
        reconcileActiveState()
        onSessionClosed?(id)
        persistNow()
    }

    func relaunchSession(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        if let tabs = tabsBySession[id] {
            for controllerID in Set(tabs.flatMap(\.allControllerIDs)) {
                runtimeControllers[controllerID]?.terminate()
                runtimeControllers.removeValue(forKey: controllerID)
                ownerSessionIDByControllerID.removeValue(forKey: controllerID)
                clearLaunchTracking(for: controllerID)
            }
        } else {
            runtimeControllers[id]?.terminate()
            runtimeControllers.removeValue(forKey: id)
            ownerSessionIDByControllerID.removeValue(forKey: id)
            clearLaunchTracking(for: id)
        }
        setStatusText(for: id, text: nil)
        ensureController(for: id)?.requestLaunchIfNeeded()
        if selectedSessionID == id {
            ensureController(for: id)?.focus()
        }
    }

    func relaunchAllSessions() {
        for session in sessions {
            relaunchSession(session.id)
        }
    }

    func focusNextAttentionItem() {
        guard let item = unresolvedAttentionItems.first else { return }
        focusSession(item.sessionID)
    }

    func injectAttention(sessionID: UUID, reason: AttentionReason, message: String? = nil) {
        recordAttention(sessionID: sessionID, reason: reason, message: message)
    }

    func browserController(for sessionID: UUID) -> SessionBrowserController? {
        guard sessions.contains(where: { $0.id == sessionID }) else { return nil }

        if let existing = browserControllers[sessionID] {
            return existing
        }

        guard let session = sessions.first(where: { $0.id == sessionID }) else { return nil }
        let controller = SessionBrowserController(initialURL: session.browserState?.currentURL)
        controller.onURLChanged = { [weak self] updatedURL in
            guard let self else { return }
            self.updateBrowserURLFromController(sessionID: sessionID, urlString: updatedURL)
        }
        browserControllers[sessionID] = controller
        return controller
    }

    func niriBrowserController(for sessionID: UUID, itemID: UUID) -> SessionBrowserController? {
        guard sessions.contains(where: { $0.id == sessionID }) else { return nil }
        guard let layout = niriLayoutsBySession[sessionID],
              let path = findNiriItemPath(layout: layout, itemID: itemID)
        else { return nil }

        if case .browser = layout.workspaces[path.workspaceIndex].columns[path.columnIndex].items[path.itemIndex].ref {
            if let existing = niriBrowserControllersByItemID[itemID] {
                return existing
            }

            let initialURL = sessions.first(where: { $0.id == sessionID })?.browserState?.currentURL
            let controller = SessionBrowserController(initialURL: initialURL)
            controller.onURLChanged = { [weak self] updatedURL in
                guard let self else { return }
                self.updateBrowserURLFromController(sessionID: sessionID, urlString: updatedURL)
            }
            niriBrowserControllersByItemID[itemID] = controller
            return controller
        }

        return nil
    }

    func niriAppController(for itemID: UUID, appID: String) -> (any NiriAppTileRuntimeControlling)? {
        niriAppControllersByItemID[itemID]?[appID]
    }

    func setNiriAppController(_ controller: any NiriAppTileRuntimeControlling, for itemID: UUID, appID: String) {
        var controllers = niriAppControllersByItemID[itemID] ?? [:]
        controllers[appID] = controller
        niriAppControllersByItemID[itemID] = controllers
    }

    @discardableResult
    func removeNiriAppController(for itemID: UUID, appID: String) -> (any NiriAppTileRuntimeControlling)? {
        guard var controllers = niriAppControllersByItemID[itemID] else { return nil }
        let removed = controllers.removeValue(forKey: appID)
        if controllers.isEmpty {
            niriAppControllersByItemID.removeValue(forKey: itemID)
        } else {
            niriAppControllersByItemID[itemID] = controllers
        }
        return removed
    }

    func stopNiriAppController(itemID: UUID, appID: String) {
        guard let removed = removeNiriAppController(for: itemID, appID: appID) else { return }
        removed.stop()
    }

    /// Generic typed app-controller accessor.
    /// New app integrations should use this instead of introducing app-specific getters.
    func niriAppController<T: NiriAppTileRuntimeControlling>(
        for sessionID: UUID,
        itemID: UUID,
        appID: String,
        as type: T.Type = T.self
    ) -> T? {
        if let existing = niriAppController(for: itemID, appID: appID) as? T {
            return existing
        }
        guard let created = ensureNiriAppController(for: sessionID, itemID: itemID, appID: appID) as? T else {
            return nil
        }
        return created
    }

    func launchDirectory(for sessionID: UUID) -> String {
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        return session.lastKnownCwd
            ?? session.worktreePath
            ?? session.repoPath
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    func profileSeedPath(for sessionID: UUID) -> String? {
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            return nil
        }
        return session.worktreePath
            ?? session.repoPath
            ?? session.lastKnownCwd
            ?? session.lastLaunchCwd
    }

    func makeNiriT3Controller(sessionID: UUID, itemID: UUID) -> T3TileController? {
        guard sessions.contains(where: { $0.id == sessionID }) else { return nil }
        return T3TileController(
            sessionID: sessionID,
            itemID: itemID,
            launchDirectoryProvider: { [weak self] in
                self?.launchDirectory(for: sessionID) ?? FileManager.default.homeDirectoryForCurrentUser.path
            },
            buildCoordinator: t3BuildCoordinator,
            snapshotManager: t3SnapshotManager
        )
    }

    func makeNiriVSCodeController(sessionID: UUID, itemID: UUID) -> VSCodeTileController? {
        guard sessions.contains(where: { $0.id == sessionID }) else { return nil }
        return VSCodeTileController(
            sessionID: sessionID,
            itemID: itemID,
            launchDirectoryProvider: { [weak self] in
                self?.launchDirectory(for: sessionID) ?? FileManager.default.homeDirectoryForCurrentUser.path
            },
            profileSeedPathProvider: { [weak self] in
                self?.profileSeedPath(for: sessionID)
            },
            provisioner: vscodeProvisioner,
            snapshotManager: vscodeSnapshotManager
        )
    }

    func makeNiriOpenCodeController(sessionID: UUID, itemID: UUID) -> OpenCodeTileController? {
        guard sessions.contains(where: { $0.id == sessionID }) else { return nil }
        return OpenCodeTileController(
            sessionID: sessionID,
            itemID: itemID,
            launchDirectoryProvider: { [weak self] in
                self?.launchDirectory(for: sessionID) ?? FileManager.default.homeDirectoryForCurrentUser.path
            },
            snapshotManager: openCodeSnapshotManager
        )
    }

    func retryNiriAppController(sessionID: UUID, itemID: UUID, appID: String) {
        guard let controller = ensureNiriAppController(for: sessionID, itemID: itemID, appID: appID) else { return }
        controller.retry()
    }

    @discardableResult
    func setupVSCodeBrowserDebug(for sessionID: UUID) -> Bool {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return false }

        do {
            let launchDirectoryPath = resolveVSCodeLaunchDirectory(for: session)
            let workspaceDirectories = resolveVSCodeDebugWorkspaceDirectories(for: session)
            guard !workspaceDirectories.isEmpty else {
                throw VSCodeBrowserDebugSetupError.launchDirectoryMissing(launchDirectoryPath)
            }

            var configuredPaths: [String] = []
            for workspaceDirectoryURL in workspaceDirectories {
                let webRoot = preferredVSCodeWebRoot(for: workspaceDirectoryURL)
                let launchConfigURL = try upsertVSCodeBrowserLaunchConfiguration(
                    in: workspaceDirectoryURL,
                    configurationName: vscodeBrowserDebugConfigName,
                    port: vscodeBrowserDebugPort,
                    urlFilter: vscodeBrowserDebugURLFilter,
                    webRoot: webRoot
                )
                _ = try upsertVSCodeWorkspaceDebugSettings(in: workspaceDirectoryURL)
                configuredPaths.append(launchConfigURL.path)
            }

            let browserName = try launchBrowserForVSCodeDebug(port: vscodeBrowserDebugPort)
            setStatusText(
                for: sessionID,
                text: "VS Code browser debug ready. Updated \(configuredPaths.count) workspace config(s): \(configuredPaths.joined(separator: ", ")). In VS Code, choose '\(vscodeBrowserDebugConfigName)' before pressing Play. Browser launched in \(browserName)."
            )
            return true
        } catch {
            setStatusText(for: sessionID, text: "VS Code browser debug setup failed: \(error.localizedDescription)")
            return false
        }
    }

    func toggleBrowserSplit(for sessionID: UUID) {
        guard let index = indexOfSession(sessionID) else { return }
        var state = sessions[index].browserState ?? BrowserSurfaceState(
            isVisible: false,
            currentURL: nil,
            splitSide: settings.browserSplitDefaultSide,
            splitFraction: 0.42
        )
        state.isVisible.toggle()
        sessions[index].browserState = state

        if state.isVisible {
            _ = browserController(for: sessionID)
            if state.currentURL == nil {
                sessions[index].browserState?.currentURL = "https://google.com"
            }
            if let url = sessions[index].browserState?.currentURL {
                browserControllers[sessionID]?.load(urlString: url)
            }
        }

        persistSoon()
    }

    func setBrowserURL(for sessionID: UUID, urlString: String?) {
        guard let index = indexOfSession(sessionID) else { return }
        var state = sessions[index].browserState ?? BrowserSurfaceState(
            isVisible: true,
            currentURL: nil,
            splitSide: settings.browserSplitDefaultSide,
            splitFraction: 0.42
        )
        state.isVisible = true
        state.currentURL = urlString
        sessions[index].browserState = state
        let controller = browserController(for: sessionID)
        controller?.load(urlString: urlString)
        persistSoon()
    }

    func setBrowserSplitSide(for sessionID: UUID, side: SplitSide) {
        guard let index = indexOfSession(sessionID) else { return }
        var state = sessions[index].browserState ?? BrowserSurfaceState(
            isVisible: true,
            currentURL: nil,
            splitSide: side,
            splitFraction: 0.42
        )
        state.splitSide = side
        sessions[index].browserState = state
        persistSoon()
    }

    func setBrowserSplitFraction(for sessionID: UUID, fraction: Double) {
        guard let index = indexOfSession(sessionID) else { return }
        var state = sessions[index].browserState ?? BrowserSurfaceState(
            isVisible: true,
            currentURL: nil,
            splitSide: settings.browserSplitDefaultSide,
            splitFraction: fraction
        )
        state.splitFraction = min(0.8, max(0.2, fraction))
        sessions[index].browserState = state
        persistSoon()
    }

    func openCurrentBrowserInDefaultBrowser(for sessionID: UUID) {
        guard let controller = browserController(for: sessionID) else { return }
        controller.openInDefaultBrowser()
    }

    func markTerminalFocused(for sessionID: UUID) {
        setLastFocusedSurface(for: sessionID, surface: .terminal)
    }

    func markBrowserFocused(for sessionID: UUID) {
        setLastFocusedSurface(for: sessionID, surface: .browser)
    }

    func markNiriAppFocused(for sessionID: UUID, appID: String) {
        setLastFocusedSurface(for: sessionID, surface: .app(appID: appID))
    }

    @discardableResult
    func adjustNiriFocusedWebTileZoom(for sessionID: UUID, delta: CGFloat) -> Bool {
        ensureNiriLayout(for: sessionID)
        guard let layout = niriLayoutsBySession[sessionID],
              let focusedItemID = layout.camera.focusedItemID,
              let path = findNiriItemPath(layout: layout, itemID: focusedItemID)
        else {
            return false
        }

        let focusedRef = layout.workspaces[path.workspaceIndex].columns[path.columnIndex].items[path.itemIndex].ref
        switch focusedRef {
        case .browser:
            guard let controller = niriBrowserController(for: sessionID, itemID: focusedItemID) else { return false }
            adjustWebViewZoom(controller.webView, by: delta)
            setLastFocusedSurface(for: sessionID, surface: .browser)
            return true
        case .app(let appID):
            guard let controller = ensureNiriAppController(for: sessionID, itemID: focusedItemID, appID: appID) else {
                return false
            }
            guard controller.adjustZoom(by: delta) else { return false }
            setLastFocusedSurface(for: sessionID, surface: .app(appID: appID))
            return true
        case .terminal:
            return false
        }
    }

    func openURLInSplit(_ url: URL, for sessionID: UUID?) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            do {
                try URLRoutingService(openLinksInDefaultBrowser: true).open(url)
            } catch {
                Logger.error("Failed to open URL in browser split: \(error.localizedDescription)")
            }
            return
        }

        guard let sessionID else {
            do {
                try URLRoutingService(openLinksInDefaultBrowser: true).open(url)
            } catch {
                Logger.error("Failed to open URL in default browser: \(error.localizedDescription)")
            }
            return
        }

        setBrowserURL(for: sessionID, urlString: url.absoluteString)
        setLastFocusedSurface(for: sessionID, surface: .browser)
    }

    @discardableResult
    func openClipboardURLInSplit(for sessionID: UUID?) -> Bool {
        guard let value = NSPasteboard.general.string(forType: .string),
              let url = normalizedURL(from: value) else {
            return false
        }
        openURLInSplit(url, for: sessionID ?? selectedSessionID)
        return true
    }

    func revealWorktree(for sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              let worktreePath = session.worktreePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktreePath)])
    }

    func openWorktreeInNewSession(for sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              let worktreePath = session.worktreePath else { return }
        createQuickSession(
            atPath: worktreePath,
            title: "\(session.title) (Worktree)"
        )
    }

    func inspectWorktreeState(for sessionID: UUID) async {
        guard let index = indexOfSession(sessionID),
              let repoPath = sessions[index].repoPath,
              let worktreePath = sessions[index].worktreePath else { return }
        do {
            let state = try await worktreeService.inspectWorktree(
                repoPath: repoPath,
                worktreePath: worktreePath
            )
            sessions[index].worktreeState = state
            if state == .missingOnDisk {
                sessions[index].statusText = "Worktree missing. Reattach or recreate before relaunch."
            }
            persistSoon()
        } catch {
            setStatusText(for: sessionID, text: "Worktree inspection failed: \(error.localizedDescription)")
        }
    }

    func inspectWorktrees(repoPath: String) async throws -> [WorktreeInspectionItem] {
        let worktrees = try await worktreeService.listWorktrees(repoPath: repoPath)
        var items: [WorktreeInspectionItem] = []
        for worktree in worktrees {
            let state = try await worktreeService.inspectWorktree(
                repoPath: repoPath,
                worktreePath: worktree.worktreePath
            )
            items.append(
                WorktreeInspectionItem(
                    repoPath: repoPath,
                    worktreePath: worktree.worktreePath,
                    branchName: worktree.branchName,
                    state: state
                )
            )
        }
        return items.sorted { lhs, rhs in
            if lhs.branchName != rhs.branchName {
                return lhs.branchName.localizedCaseInsensitiveCompare(rhs.branchName) == .orderedAscending
            }
            return lhs.worktreePath.localizedCaseInsensitiveCompare(rhs.worktreePath) == .orderedAscending
        }
    }

    func promptDeleteWorktree(for sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              let worktreePath = session.worktreePath,
              let repoPath = session.repoPath else { return }

        pendingWorktreeDeletePrompt = WorktreeDeletePrompt(
            sessionID: session.id,
            sessionTitle: session.title,
            repoPath: repoPath,
            branchName: session.branchName,
            worktreePath: worktreePath
        )
        if let index = indexOfSession(sessionID) {
            sessions[index].worktreeState = .pendingDeletion
            persistSoon()
        }
    }

    func dismissWorktreeDeletePrompt() {
        if let sessionID = pendingWorktreeDeletePrompt?.sessionID,
           let index = indexOfSession(sessionID),
           sessions[index].isWorktreeBacked {
            sessions[index].worktreeState = .attached
        }
        pendingWorktreeDeletePrompt = nil
    }

    func presentWorktreeInspector(repoPath: String) {
        pendingWorktreeInspector = WorktreeInspectorRequest(repoPath: repoPath)
    }

    func dismissWorktreeInspector() {
        pendingWorktreeInspector = nil
    }

    func confirmDeleteWorktreePrompt() async {
        guard let prompt = pendingWorktreeDeletePrompt else { return }
        pendingWorktreeDeletePrompt = nil

        do {
            try await worktreeService.deleteWorktreeIfClean(
                repoPath: prompt.repoPath,
                worktreePath: prompt.worktreePath
            )

            if let index = indexOfSession(prompt.sessionID) {
                sessions[index].worktreePath = nil
                sessions[index].isWorktreeBacked = false
                sessions[index].worktreeState = nil
                sessions[index].statusText = "Deleted clean worktree: \(prompt.worktreePath)"
                sessions[index].lastLaunchCwd = sessions[index].repoPath ?? FileManager.default.homeDirectoryForCurrentUser.path
                sessions[index].lastLaunchManifest = nil
            }
            persistNow()
        } catch {
            if let index = indexOfSession(prompt.sessionID) {
                sessions[index].worktreeState = .dirty
            }
            setStatusText(for: prompt.sessionID, text: "Worktree delete blocked: \(error.localizedDescription)")
        }
    }

    func updateLastActive(_ id: UUID, at date: Date) {
        guard let index = indexOfSession(id) else { return }
        sessions[index].lastActiveAt = date
    }

    func updateAttentionState(_ id: UUID, state: SessionAttentionState) {
        guard let index = indexOfSession(id) else { return }
        sessions[index].attentionState = state
        persistSoon()
    }

    func updateTerminalMetadata(_ id: UUID, cwd: String?, suggestedTitle: String?) {
        guard let index = indexOfSession(id) else { return }

        if let cwd, !cwd.isEmpty {
            sessions[index].lastKnownCwd = cwd
            sessions[index].lastLaunchCwd = cwd
            if let manifest = sessions[index].lastLaunchManifest {
                sessions[index].lastLaunchManifest = SessionLaunchManifest(
                    sessionID: manifest.sessionID,
                    cwd: normalizePath(cwd) ?? cwd,
                    shellPath: manifest.shellPath,
                    repoPath: manifest.repoPath,
                    worktreePath: manifest.worktreePath,
                    sandboxProfile: manifest.sandboxProfile,
                    networkPolicy: manifest.networkPolicy,
                    tempRoot: manifest.tempRoot,
                    environment: manifest.environment,
                    projectID: manifest.projectID,
                    ipcSocketPath: manifest.ipcSocketPath
                )
            }

            // Detect git branch and diff stats for the current working directory
            let sessionID = id
            let cwdCopy = cwd
            Task { @MainActor [weak self] in
                let (branch, diffStat) = await Task.detached {
                    let git = GitService()
                    let branch = try? await git.currentBranch(repoPath: cwdCopy)
                    let stat = (branch != nil) ? (try? await git.diffStat(path: cwdCopy)) : nil
                    return (branch, stat)
                }.value
                guard let self, let idx = self.indexOfSession(sessionID) else { return }
                var changed = false
                if self.sessions[idx].branchName != branch {
                    self.sessions[idx].branchName = branch
                    changed = true
                }
                if self.sessions[idx].lastDiffStat != diffStat {
                    self.sessions[idx].lastDiffStat = diffStat
                    changed = true
                }
                if changed { self.persistSoon() }
            }
        }

        if let suggestedTitle,
           !suggestedTitle.isEmpty,
           !sessions[index].hasCustomTitle {
            sessions[index].title = suggestedTitle
        }

        synchronizeProjectGroups()
        persistSoon()
    }

    func saveSettings(_ updater: (inout AppSettings) -> Void) {
        let oldRestoreBehavior = settings.restoreBehavior
        updater(&settings)

        if oldRestoreBehavior != settings.restoreBehavior {
            applyRestoreBehaviorOnLaunch()
        }

        // Settings writes should be durable immediately so new service instances
        // don't observe stale restore behavior during rapid relaunch cycles.
        persistNow()
    }

    func isGitRepository(path: String) async -> Bool {
        guard let normalizedPath = normalizePath(path) else { return false }
        return (try? await worktreeService.validateRepo(path: normalizedPath)) != nil
    }

    func prepareForTermination() {
        saveAllScrollback()
        persistNow()
        let controllers = Array(runtimeControllers.values)
        controllers.forEach { $0.terminate(freeSynchronously: true) }
        runtimeControllers.removeAll()
        ownerSessionIDByControllerID.removeAll()
        launchStartedAtByControllerID.removeAll()
        launchUsedWrapperByControllerID.removeAll()
        launchInitializedControllerIDs.removeAll()
        wrapperFallbackAppliedBySessionID.removeAll()
        browserControllers.removeAll()
        niriBrowserControllersByItemID.removeAll()
        for (itemID, controllers) in Array(niriAppControllersByItemID) {
            for (appID, _) in controllers {
                stopNiriAppController(itemID: itemID, appID: appID)
            }
        }
        niriAppControllersByItemID.removeAll()
        niriLayoutsBySession.removeAll()
        host.shutdown(freeSurfacesSynchronously: true)
    }

    // MARK: - Scrollback Persistence

    private var scrollbackDirectory: URL {
        launcherDirectory.deletingLastPathComponent().appendingPathComponent("scrollback", isDirectory: true)
    }

    func scrollbackFile(for sessionID: UUID) -> URL {
        scrollbackDirectory.appendingPathComponent("\(sessionID.uuidString).txt", isDirectory: false)
    }

    func saveAllScrollback() {
        let fm = FileManager.default
        try? fm.createDirectory(at: scrollbackDirectory, withIntermediateDirectories: true)

        for (sessionID, controller) in runtimeControllers {
            guard let surface = controller.terminalSurface else { continue }
            if let text = host.dumpScrollback(surface), !text.isEmpty {
                // Cap at ~500KB to avoid storing huge scrollback
                let maxLen = 500_000
                let trimmed = text.count > maxLen ? String(text.suffix(maxLen)) : text
                try? trimmed.write(to: scrollbackFile(for: sessionID), atomically: true, encoding: .utf8)
            }
        }
    }

    func loadScrollback(for sessionID: UUID) -> String? {
        let file = scrollbackFile(for: sessionID)
        guard let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty else { return nil }
        // Clean up after loading so we don't replay stale scrollback next time
        try? FileManager.default.removeItem(at: file)
        return text
    }

    func dismissWorktreeCleanupNotice() {
        pendingWorktreeCleanupNotice = nil
    }

    func dismissStatusText(for sessionID: UUID) {
        setStatusText(for: sessionID, text: nil)
    }

    func postStatusMessage(_ text: String?, for sessionID: UUID) {
        setStatusText(for: sessionID, text: text)
    }

    func setAgentActivity(for sessionID: UUID, activity: AgentActivity?) {
        guard let index = indexOfSession(sessionID) else { return }
        sessions[index].agentActivity = activity
    }

    func setDiffStat(for sessionID: UUID, stat: DiffStat?) {
        guard let index = indexOfSession(sessionID) else { return }
        sessions[index].lastDiffStat = stat
    }

    /// Pre-generate shared launcher scripts so the first session launch is faster.
}
