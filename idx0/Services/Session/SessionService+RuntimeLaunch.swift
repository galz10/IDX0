import AppKit
import Foundation
import WebKit

extension SessionService {
    func prewarmLauncherScripts() {
        let dummyID = UUID()
        let manifest = SessionLaunchManifest(
            sessionID: dummyID,
            cwd: NSHomeDirectory(),
            shellPath: "/bin/zsh",
            repoPath: nil,
            worktreePath: nil,
            sandboxProfile: .fullAccess,
            networkPolicy: .inherited,
            tempRoot: nil,
            environment: [:],
            projectID: nil,
            ipcSocketPath: nil
        )
        do {
            try launcherClient.persistManifest(manifest)
            _ = try launcherClient.commandPath(for: manifest)
        } catch {
            // Non-fatal
        }
        launcherClient.clearLaunchResult(sessionID: dummyID)
        // Clean up the dummy session directory
        let dummyDir = launcherDirectory.appendingPathComponent(dummyID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dummyDir)
    }

    func paneController(for controllerID: UUID) -> TerminalSessionController? {
        runtimeControllers[controllerID]
    }

    /// Imperative pane lookup for command handlers that need to create a
    /// controller when it doesn't exist yet.
    @discardableResult
    func ensurePaneController(for controllerID: UUID) -> TerminalSessionController? {
        if let existing = runtimeControllers[controllerID] {
            return existing
        }
        guard let ownerSessionID = ownerSessionID(forControllerID: controllerID) else { return nil }
        guard pendingPaneControllerEnsureIDs.insert(controllerID).inserted else { return nil }

        // Defer controller creation so we don't publish SwiftUI state while view updates are in-flight.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            _ = self.ensureController(forControllerID: controllerID, ownerSessionID: ownerSessionID)
            self.pendingPaneControllerEnsureIDs.remove(controllerID)
        }
        return nil
    }

    /// Read-only controller lookup used by SwiftUI view rendering.
    func controller(for sessionID: UUID) -> TerminalSessionController? {
        guard sessions.contains(where: { $0.id == sessionID }) else {
            return nil
        }
        let controllerID = activeControllerID(for: sessionID) ?? sessionID
        return runtimeControllers[controllerID]
    }

    @discardableResult
    func ensureController(for sessionID: UUID) -> TerminalSessionController? {
        guard sessions.contains(where: { $0.id == sessionID }) else {
            return nil
        }
        let controllerID = activeControllerID(for: sessionID) ?? sessionID
        return ensureController(forControllerID: controllerID, ownerSessionID: sessionID)
    }

    func ensureController(forControllerID controllerID: UUID, ownerSessionID: UUID) -> TerminalSessionController? {
        if let existing = runtimeControllers[controllerID] {
            return existing
        }

        guard let index = indexOfSession(ownerSessionID) else {
            return nil
        }
        let session = sessions[index]
        let launchPreparation = prepareLaunch(for: session)

        sessions[index].sandboxEnforcementState = launchPreparation.enforcementState
        if let statusText = launchPreparation.statusText {
            sessions[index].statusText = statusText
        } else if sessions[index].statusText == nil
            || sessions[index].statusText?.hasPrefix("Restrictions") == true
            || sessions[index].statusText?.hasPrefix("Sandbox launch failed") == true
            || sessions[index].statusText?.hasPrefix("Worktree missing") == true
            || sessions[index].statusText?.hasPrefix("Launch folder missing") == true
            || sessions[index].statusText?.hasPrefix("Shell not found") == true
            || sessions[index].statusText?.hasPrefix("Launch helper unavailable") == true
            || sessions[index].statusText?.hasPrefix("Launch manifest unavailable") == true {
            sessions[index].statusText = nil
        }
        persistSoon()

        let controller = TerminalSessionController(
            sessionID: controllerID,
            launchDirectory: launchPreparation.launchDirectory,
            shellPath: launchPreparation.commandPath,
            launchBlockedReason: launchPreparation.launchBlockedReason,
            host: host
        )
        launchStartedAtByControllerID[controllerID] = Date()
        launchUsedWrapperByControllerID[controllerID] = (launchPreparation.commandPath != session.shellPath)
        launchInitializedControllerIDs.remove(controllerID)
        controller.onRuntimeStateChanged = { [weak self] state in
            guard let self else { return }
            switch state {
            case .launching:
                self.scheduleWrapperStartupProbe(controllerID: controllerID, sessionID: ownerSessionID)
            case .running:
                self.applyLaunchResultIfAvailable(for: ownerSessionID)
                if self.launchUsedWrapperByControllerID[controllerID] == true,
                   self.launcherClient.loadLaunchResult(sessionID: ownerSessionID) != nil {
                    // Helper script reported launch status, so avoid eager fallback
                    // relaunches that can cause a visible "double load" flash.
                    self.cancelWrapperStartupProbe(for: controllerID)
                }
                if self.sessions.first(where: { $0.id == ownerSessionID })?.sandboxEnforcementState != .degraded {
                    self.setStatusText(for: ownerSessionID, text: nil)
                }
                self.resolveAttentionIfNotError(sessionID: ownerSessionID)
                self.onSessionLaunched?(ownerSessionID)
            case .failedToLaunch(let message):
                self.cancelWrapperStartupProbe(for: controllerID)
                if self.shouldRetryWrapperLaunchWithDirectShell(controllerID: controllerID, sessionID: ownerSessionID) {
                    _ = self.retryWrapperLaunchWithDirectShell(
                        controllerID: controllerID,
                        sessionID: ownerSessionID,
                        statusText: "Launcher wrapper failed. Retrying with direct shell."
                    )
                    return
                }
                self.setStatusText(for: ownerSessionID, text: "Launch failed: \(message)")
                self.recordAttention(
                    sessionID: ownerSessionID,
                    reason: .error,
                    message: "Launch failed"
                )
                self.onSessionErrored?(ownerSessionID, message)
            case .terminated(let exitCode):
                self.cancelWrapperStartupProbe(for: controllerID)
                if let exitCode {
                    if exitCode == 0 {
                        self.setStatusText(for: ownerSessionID, text: "Terminal process exited")
                        self.recordAttention(
                            sessionID: ownerSessionID,
                            reason: .completed,
                            message: "Process exited cleanly"
                        )
                        self.onSessionCompleted?(ownerSessionID, "Process exited cleanly")
                    } else {
                        self.setStatusText(for: ownerSessionID, text: "Terminal process exited (\(exitCode))")
                        self.recordAttention(
                            sessionID: ownerSessionID,
                            reason: .error,
                            message: "Process exited with code \(exitCode)"
                        )
                        self.onSessionErrored?(ownerSessionID, "Process exited with code \(exitCode)")
                    }
                } else {
                    self.setStatusText(for: ownerSessionID, text: "Terminal process exited")
                    self.recordAttention(
                        sessionID: ownerSessionID,
                        reason: .completed,
                        message: "Terminal process exited"
                    )
                    self.onSessionCompleted?(ownerSessionID, "Terminal process exited")
                }
            case .idle:
                break
            }
        }

        runtimeControllers[controllerID] = controller
        ownerSessionIDByControllerID[controllerID] = ownerSessionID
        return controller
    }

    func openURL(_ url: URL, preferredSessionID: UUID? = nil) {
        let allowedSchemes = ["http", "https", "mailto"]
        guard let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else { return }

        let router = URLRoutingService(openLinksInDefaultBrowser: settings.openLinksInDefaultBrowser)
        let preferredEmbeddedSessionID: UUID? = {
            guard let preferredSessionID else { return nil }
            return sessions.contains(where: { $0.id == preferredSessionID }) ? preferredSessionID : nil
        }()
        switch router.target(for: url) {
        case .embeddedBrowser:
            guard let targetSessionID = preferredEmbeddedSessionID ?? selectedSessionID else {
                do {
                    try router.open(url)
                } catch {
                    Logger.error("Failed to open URL: \(error.localizedDescription)")
                }
                return
            }

            if settings.niriCanvasEnabled,
               openURLInNiriEmbeddedBrowser(url, for: targetSessionID) {
                return
            }

            setBrowserURL(for: targetSessionID, urlString: url.absoluteString)
            setLastFocusedSurface(for: targetSessionID, surface: .browser)

        case .externalBrowser:
            do {
                try router.open(url)
            } catch {
                Logger.error("Failed to open URL: \(error.localizedDescription)")
            }
        }
    }

    func openURLInNiriEmbeddedBrowser(_ url: URL, for sessionID: UUID) -> Bool {
        ensureNiriLayout(for: sessionID)
        guard let layout = niriLayoutsBySession[sessionID] else { return false }

        let focusedBrowserItemID: UUID? = {
            guard let focusedItemID = layout.camera.focusedItemID,
                  let path = findNiriItemPath(layout: layout, itemID: focusedItemID)
            else { return nil }

            if case .browser = layout.workspaces[path.workspaceIndex].columns[path.columnIndex].items[path.itemIndex].ref {
                return focusedItemID
            }
            return nil
        }()

        let existingBrowserItemID = focusedBrowserItemID ?? niriBrowserItemIDs(in: layout).first
        let targetItemID = existingBrowserItemID ?? niriAddBrowserRight(in: sessionID)
        guard let targetItemID,
              let controller = niriBrowserController(for: sessionID, itemID: targetItemID) else {
            return false
        }

        controller.load(urlString: url.absoluteString)
        updateBrowserURLFromController(sessionID: sessionID, urlString: url.absoluteString)
        niriSelectItem(sessionID: sessionID, itemID: targetItemID)
        setLastFocusedSurface(for: sessionID, surface: .browser)
        return true
    }

    func sandboxWritableRoots(for sessionID: UUID) -> [String] {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return [] }

        switch session.sandboxProfile {
        case .fullAccess:
            return ["Full Access: user-writable filesystem"]
        case .worktreeWrite:
            if let writeRoot = session.worktreePath ?? session.repoPath {
                return [writeRoot]
            }
            return ["Unavailable: missing repo/worktree root"]
        case .worktreeAndTemp:
            var roots: [String] = []
            if let writeRoot = session.worktreePath ?? session.repoPath {
                roots.append(writeRoot)
            } else {
                roots.append("Unavailable: missing repo/worktree root")
            }
            roots.append(session.lastLaunchManifest?.tempRoot ?? defaultTempRoot(for: session.id))
            return roots
        }
    }

    private struct LaunchPreparation {
        let commandPath: String
        let launchDirectory: String
        let launchBlockedReason: String?
        let enforcementState: SandboxEnforcementState
        let statusText: String?
    }

    private struct LaunchPreflightResult {
        let launchDirectory: String
        let launchBlockedReason: String?
        let statusText: String?
    }

    private func prepareLaunch(for session: Session) -> LaunchPreparation {
        let manifest = resolveLaunchManifest(for: session)
        let preflight = preflightLaunch(for: session, manifest: manifest)
        if wrapperFallbackAppliedBySessionID.contains(session.id) {
            let fallbackStatus = preflight.statusText ?? "Recovered launcher failure by using direct shell startup."
            return LaunchPreparation(
                commandPath: manifest.shellPath,
                launchDirectory: preflight.launchDirectory,
                launchBlockedReason: preflight.launchBlockedReason,
                enforcementState: .unenforced,
                statusText: fallbackStatus
            )
        }
        let restriction = evaluateRestrictionState(for: manifest)
        launcherClient.clearLaunchResult(sessionID: session.id)

        do {
            try launcherClient.persistManifest(manifest)
            updateStoredLaunchManifest(manifest, for: session.id)
        } catch {
            let fallbackStatus = "Launch manifest unavailable: \(error.localizedDescription)"
            return LaunchPreparation(
                commandPath: manifest.shellPath,
                launchDirectory: preflight.launchDirectory,
                launchBlockedReason: preflight.launchBlockedReason,
                enforcementState: restriction.enforcementState == .enforced ? .degraded : restriction.enforcementState,
                statusText: restriction.statusText ?? preflight.statusText ?? fallbackStatus
            )
        }

        do {
            let commandPath = try launcherClient.commandPath(for: manifest)
            return LaunchPreparation(
                commandPath: commandPath,
                launchDirectory: preflight.launchDirectory,
                launchBlockedReason: preflight.launchBlockedReason,
                enforcementState: restriction.enforcementState,
                statusText: restriction.statusText ?? preflight.statusText
            )
        } catch {
            let fallbackState: SandboxEnforcementState = restriction.enforcementState == .enforced ? .degraded : restriction.enforcementState
            return LaunchPreparation(
                commandPath: manifest.shellPath,
                launchDirectory: preflight.launchDirectory,
                launchBlockedReason: preflight.launchBlockedReason,
                enforcementState: fallbackState,
                statusText: "Launch helper unavailable: \(error.localizedDescription)"
            )
        }
    }

    private func preflightLaunch(for session: Session, manifest: SessionLaunchManifest) -> LaunchPreflightResult {
        let fallbackDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let launchDirectory = normalizePath(manifest.cwd) ?? fallbackDirectory
        let shellPath = manifest.shellPath

        if !FileManager.default.isExecutableFile(atPath: shellPath) {
            return LaunchPreflightResult(
                launchDirectory: fallbackDirectory,
                launchBlockedReason: "Shell not found. Update preferences or session settings.",
                statusText: "Shell not found. Update preferences or session settings."
            )
        }

        if session.isWorktreeBacked {
            let worktreePath = normalizePath(manifest.worktreePath) ?? normalizePath(session.worktreePath)
            guard let worktreePath else {
                return LaunchPreflightResult(
                    launchDirectory: fallbackDirectory,
                    launchBlockedReason: "Worktree missing. Reattach or recreate before relaunch.",
                    statusText: "Worktree missing. Reattach or recreate before relaunch."
                )
            }
            if !directoryExists(worktreePath) {
                return LaunchPreflightResult(
                    launchDirectory: fallbackDirectory,
                    launchBlockedReason: "Worktree missing. Reattach or recreate before relaunch.",
                    statusText: "Worktree missing. Reattach or recreate before relaunch."
                )
            }
        }

        if !directoryExists(launchDirectory) {
            return LaunchPreflightResult(
                launchDirectory: fallbackDirectory,
                launchBlockedReason: "Launch folder missing. Update session folder before relaunch.",
                statusText: "Launch folder missing. Update session folder before relaunch."
            )
        }

        return LaunchPreflightResult(
            launchDirectory: launchDirectory,
            launchBlockedReason: nil,
            statusText: nil
        )
    }

    func buildLaunchManifest(for session: Session, tempRoot: String?) -> SessionLaunchManifest {
        var environment = session.lastLaunchManifest?.environment ?? [:]
        environment["IDX0_SESSION_ID"] = session.id.uuidString
        environment["IDX0_PROJECT_ID"] = session.projectID?.uuidString ?? ""
        environment["IDX0_IPC_SOCKET"] = ipcSocketPath

        return SessionLaunchManifest(
            sessionID: session.id,
            cwd: normalizePath(session.launchDirectory) ?? FileManager.default.homeDirectoryForCurrentUser.path,
            shellPath: session.shellPath,
            repoPath: normalizePath(session.repoPath),
            worktreePath: normalizePath(session.worktreePath),
            sandboxProfile: session.sandboxProfile,
            networkPolicy: session.networkPolicy,
            tempRoot: tempRoot,
            environment: environment,
            projectID: session.projectID?.uuidString,
            ipcSocketPath: ipcSocketPath
        )
    }

    func resolveLaunchManifest(for session: Session) -> SessionLaunchManifest {
        if let existing = session.lastLaunchManifest {
            return normalizedLaunchManifest(existing, for: session)
        }

        if let persisted = launcherClient.loadPersistedManifest(sessionID: session.id) {
            return normalizedLaunchManifest(persisted, for: session)
        }

        let tempRoot = session.sandboxProfile == .worktreeAndTemp ? defaultTempRoot(for: session.id) : nil
        return buildLaunchManifest(for: session, tempRoot: tempRoot)
    }

    func normalizedLaunchManifest(_ manifest: SessionLaunchManifest, for session: Session) -> SessionLaunchManifest {
        let cwd = normalizePath(manifest.cwd)
            ?? normalizePath(session.lastLaunchCwd)
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let shellPath = manifest.shellPath.isEmpty ? session.shellPath : manifest.shellPath
        let repoPath = normalizePath(manifest.repoPath) ?? normalizePath(session.repoPath)
        let worktreePath = normalizePath(manifest.worktreePath) ?? normalizePath(session.worktreePath)
        let tempRoot: String?
        if session.sandboxProfile == .worktreeAndTemp {
            tempRoot = normalizePath(manifest.tempRoot) ?? defaultTempRoot(for: session.id)
        } else {
            tempRoot = nil
        }

        return SessionLaunchManifest(
            sessionID: session.id,
            cwd: cwd,
            shellPath: shellPath,
            repoPath: repoPath,
            worktreePath: worktreePath,
            sandboxProfile: session.sandboxProfile,
            networkPolicy: session.networkPolicy,
            tempRoot: tempRoot,
            environment: [
                "IDX0_SESSION_ID": session.id.uuidString,
                "IDX0_PROJECT_ID": session.projectID?.uuidString ?? "",
                "IDX0_IPC_SOCKET": manifest.ipcSocketPath ?? ipcSocketPath,
            ].merging(manifest.environment) { current, _ in current },
            projectID: session.projectID?.uuidString ?? manifest.projectID,
            ipcSocketPath: manifest.ipcSocketPath ?? ipcSocketPath
        )
    }

    func evaluateRestrictionState(for manifest: SessionLaunchManifest) -> (enforcementState: SandboxEnforcementState, statusText: String?) {
        guard manifest.sandboxProfile != .fullAccess else {
            return (.unenforced, nil)
        }

        let writeRoot = normalizePath(manifest.worktreePath) ?? normalizePath(manifest.repoPath)
        guard let writeRoot, directoryExists(writeRoot) else {
            return (.degraded, "Restrictions unavailable: missing repo/worktree root.")
        }

        guard FileManager.default.isExecutableFile(atPath: sandboxExecutablePath) else {
            return (.degraded, "Restrictions unavailable: sandbox-exec not found.")
        }

        return (.enforced, nil)
    }

    func shouldRetryWrapperLaunchWithDirectShell(controllerID: UUID, sessionID: UUID) -> Bool {
        guard launchUsedWrapperByControllerID[controllerID] == true else { return false }
        guard !wrapperFallbackAppliedBySessionID.contains(sessionID) else { return false }
        guard let startedAt = launchStartedAtByControllerID[controllerID] else { return false }
        guard Date().timeIntervalSince(startedAt) <= wrapperRetryWindowSeconds else { return false }
        // Treat launch as failed until Ghostty reports terminal activity.
        // launch-result.json only confirms helper execution, not shell readiness.
        guard !launchInitializedControllerIDs.contains(controllerID) else { return false }
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return false }
        return FileManager.default.isExecutableFile(atPath: session.shellPath)
    }

    @discardableResult
    func retryWrapperLaunchWithDirectShell(
        controllerID: UUID,
        sessionID: UUID,
        statusText: String
    ) -> Bool {
        guard shouldRetryWrapperLaunchWithDirectShell(controllerID: controllerID, sessionID: sessionID) else {
            return false
        }
        wrapperFallbackAppliedBySessionID.insert(sessionID)
        clearLaunchTracking(for: controllerID)
        setStatusText(for: sessionID, text: statusText)
        relaunchSession(sessionID)
        return true
    }

    func scheduleWrapperStartupProbe(controllerID: UUID, sessionID: UUID) {
        guard launchUsedWrapperByControllerID[controllerID] == true else { return }
        cancelWrapperStartupProbe(for: controllerID)
        wrapperStartupProbeTaskByControllerID[controllerID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.wrapperStartupProbeTaskByControllerID.removeValue(forKey: controllerID)
            }
            try? await Task.sleep(nanoseconds: self.wrapperStartupProbeDelayNanoseconds)
            guard !Task.isCancelled else { return }
            if self.launchInitializedControllerIDs.contains(controllerID) {
                return
            }
            if self.launcherClient.loadLaunchResult(sessionID: sessionID) != nil {
                return
            }
            _ = self.retryWrapperLaunchWithDirectShell(
                controllerID: controllerID,
                sessionID: sessionID,
                statusText: "Launcher wrapper did not initialize. Retrying with direct shell."
            )
        }
    }

    func cancelWrapperStartupProbe(for controllerID: UUID) {
        wrapperStartupProbeTaskByControllerID[controllerID]?.cancel()
        wrapperStartupProbeTaskByControllerID.removeValue(forKey: controllerID)
    }

    func clearLaunchTracking(for controllerID: UUID) {
        cancelWrapperStartupProbe(for: controllerID)
        launchStartedAtByControllerID.removeValue(forKey: controllerID)
        launchUsedWrapperByControllerID.removeValue(forKey: controllerID)
        launchInitializedControllerIDs.remove(controllerID)
    }

    func defaultTempRoot(for sessionID: UUID) -> String {
        launcherDirectory
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("temp", isDirectory: true)
            .path
    }

    func updateStoredLaunchManifest(_ manifest: SessionLaunchManifest, for sessionID: UUID) {
        guard let index = indexOfSession(sessionID) else { return }
        if sessions[index].lastLaunchManifest != manifest {
            sessions[index].lastLaunchManifest = manifest
        }
    }

    func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    func applyLaunchResultIfAvailable(for sessionID: UUID) {
        guard let result = launcherClient.loadLaunchResult(sessionID: sessionID),
              let index = indexOfSession(sessionID) else {
            return
        }

        sessions[index].sandboxEnforcementState = result.enforcementState
        if let message = result.message, !message.isEmpty {
            sessions[index].statusText = message
        } else if result.enforcementState != .degraded,
                  isRestrictionStatus(sessions[index].statusText) {
            sessions[index].statusText = nil
        }
        persistSoon()
    }

    func isRestrictionStatus(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.hasPrefix("Restrictions")
            || text.hasPrefix("Sandbox launch failed")
            || text.hasPrefix("Launch helper unavailable")
            || text.hasPrefix("Launch manifest unavailable")
    }

    func updateBrowserURLFromController(sessionID: UUID, urlString: String?) {
        guard let index = indexOfSession(sessionID) else { return }
        if sessions[index].browserState == nil {
            sessions[index].browserState = BrowserSurfaceState(
                isVisible: false,
                currentURL: nil,
                splitSide: settings.browserSplitDefaultSide,
                splitFraction: 0.42
            )
        }
        if sessions[index].browserState?.currentURL == urlString { return }
        sessions[index].browserState?.currentURL = urlString
        persistSoon()
    }

    func installGhosttyCallbacks() {
        host.onSurfaceTitle = { [weak self] controllerID, title in
            guard let self else { return }
            self.launchInitializedControllerIDs.insert(controllerID)
            let sessionID = self.ownerSessionID(forControllerID: controllerID) ?? controllerID
            self.updateTerminalMetadata(sessionID, cwd: nil, suggestedTitle: title)
        }

        host.onSurfaceCwd = { [weak self] controllerID, cwd in
            guard let self else { return }
            self.launchInitializedControllerIDs.insert(controllerID)
            let sessionID = self.ownerSessionID(forControllerID: controllerID) ?? controllerID
            self.updateTerminalMetadata(sessionID, cwd: cwd, suggestedTitle: nil)
        }

        host.onSurfaceAttention = { [weak self] controllerID in
            guard let self else { return }
            let sessionID = self.ownerSessionID(forControllerID: controllerID) ?? controllerID
            self.recordAttention(
                sessionID: sessionID,
                reason: .needsInput,
                message: "Session requested input"
            )
            self.onSessionNeedsInput?(sessionID, "Session requested input")
        }

        host.onSurfaceClose = { [weak self] controllerID in
            guard let self else { return }
            let sessionID = self.ownerSessionID(forControllerID: controllerID) ?? controllerID
            if self.shouldRetryWrapperLaunchWithDirectShell(controllerID: controllerID, sessionID: sessionID) {
                _ = self.retryWrapperLaunchWithDirectShell(
                    controllerID: controllerID,
                    sessionID: sessionID,
                    statusText: "Launcher wrapper failed. Retrying with direct shell."
                )
                return
            }

            self.runtimeControllers[controllerID]?.markProcessExited()
            self.clearLaunchTracking(for: controllerID)
            self.setStatusText(for: sessionID, text: "Terminal process exited")
            self.recordAttention(
                sessionID: sessionID,
                reason: .completed,
                message: "Terminal closed"
            )
            self.onSessionCompleted?(sessionID, "Terminal closed")
        }

        host.onOpenURL = { [weak self] controllerID, url in
            guard let self else { return }
            let sessionID = self.ownerSessionID(forControllerID: controllerID) ?? controllerID
            self.openURL(url, preferredSessionID: sessionID)
        }
    }
}
