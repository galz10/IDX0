import AppKit
import Foundation
import UserNotifications
import WebKit

extension SessionService {
    func ownerSessionID(forControllerID controllerID: UUID) -> UUID? {
        if let owner = ownerSessionIDByControllerID[controllerID] {
            return owner
        }
        for (sessionID, tabs) in tabsBySession where tabs.contains(where: { $0.allControllerIDs.contains(controllerID) }) {
            ownerSessionIDByControllerID[controllerID] = sessionID
            return sessionID
        }
        return nil
    }

    func normalizeRepoPath(_ value: String?) -> String? {
        normalizePath(value)
    }

    func normalizePath(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath).standardizedFileURL.path
    }

    func expandedTerminalStartupCommand(
        for sessionID: UUID,
        launchDirectory: String
    ) -> String? {
        guard let template = settings.terminalStartupCommandTemplate?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !template.isEmpty
        else {
            return nil
        }

        let escapedWorkdir = GhosttyAppHost.shellEscapedCommand(launchDirectory)
        return template
            .replacingOccurrences(of: "${WORKDIR}", with: escapedWorkdir)
            .replacingOccurrences(of: "${SESSION_ID}", with: sessionID.uuidString)
    }

    func queueTerminalStartupCommandIfNeeded(
        controller: TerminalSessionController,
        ownerSessionID: UUID,
        launchDirectory: String
    ) {
        guard let command = expandedTerminalStartupCommand(
            for: ownerSessionID,
            launchDirectory: launchDirectory
        ) else {
            return
        }
        controller.send(text: command + "\n")
    }

    func normalizedURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let parsed = URL(string: trimmed), let scheme = parsed.scheme, !scheme.isEmpty {
            return parsed
        }

        return URL(string: "https://\(trimmed)")
    }

    func resolveVSCodeLaunchDirectory(for session: Session) -> String {
        normalizePath(session.lastKnownCwd)
            ?? normalizePath(session.worktreePath)
            ?? normalizePath(session.repoPath)
            ?? normalizePath(session.lastLaunchCwd)
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    func resolveVSCodeDebugWorkspaceDirectories(for session: Session) -> [URL] {
        let fileManager = FileManager.default
        var seen: Set<String> = []
        var directories: [URL] = []

        func appendIfDirectory(path: String?) {
            guard let normalized = normalizePath(path) else { return }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: normalized, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                return
            }
            let url = URL(fileURLWithPath: normalized, isDirectory: true).standardizedFileURL
            guard seen.insert(url.path).inserted else { return }
            directories.append(url)
        }

        appendIfDirectory(path: resolveVSCodeLaunchDirectory(for: session))
        appendIfDirectory(path: session.lastKnownCwd)
        appendIfDirectory(path: session.worktreePath)
        appendIfDirectory(path: session.repoPath)
        appendIfDirectory(path: session.lastLaunchCwd)

        // Also seed likely idx-web roots for sibling and nested repo layouts.
        let seeded = directories
        for directory in seeded {
            let nestedIdxWeb = directory.appendingPathComponent("idx-web", isDirectory: true).path
            appendIfDirectory(path: nestedIdxWeb)

            let siblingIdxWeb = directory
                .deletingLastPathComponent()
                .appendingPathComponent("idx-web", isDirectory: true)
                .path
            appendIfDirectory(path: siblingIdxWeb)
        }

        return directories
    }

    func preferredVSCodeWebRoot(for workspaceDirectoryURL: URL) -> String {
        if workspaceDirectoryURL.lastPathComponent == "idx-web" {
            return "${workspaceFolder}"
        }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let nestedIdxWeb = workspaceDirectoryURL.appendingPathComponent("idx-web", isDirectory: true)
        if fileManager.fileExists(atPath: nestedIdxWeb.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return "${workspaceFolder}/idx-web"
        }

        let siblingIdxWeb = workspaceDirectoryURL
            .deletingLastPathComponent()
            .appendingPathComponent("idx-web", isDirectory: true)
        if fileManager.fileExists(atPath: siblingIdxWeb.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            // Absolute path keeps source mapping stable when idx-web is a sibling repo.
            return siblingIdxWeb.path
        }

        return "${workspaceFolder}"
    }

    func upsertVSCodeBrowserLaunchConfiguration(
        in workspaceDirectoryURL: URL,
        configurationName: String,
        port: Int,
        urlFilter: String,
        webRoot: String
    ) throws -> URL {
        let fileManager = FileManager.default
        let vscodeDirectoryURL = workspaceDirectoryURL.appendingPathComponent(".vscode", isDirectory: true)
        try fileManager.createDirectory(at: vscodeDirectoryURL, withIntermediateDirectories: true)
        let launchConfigURL = vscodeDirectoryURL.appendingPathComponent("launch.json", isDirectory: false)

        let existingData: Data?
        if fileManager.fileExists(atPath: launchConfigURL.path) {
            existingData = try Data(contentsOf: launchConfigURL)
        } else {
            existingData = nil
        }

        let updatedData = try Self.upsertVSCodeBrowserAttachConfigurationData(
            existingData: existingData,
            configurationName: configurationName,
            port: port,
            urlFilter: urlFilter,
            webRoot: webRoot
        )
        try updatedData.write(to: launchConfigURL, options: .atomic)
        return launchConfigURL
    }

    func upsertVSCodeWorkspaceDebugSettings(in workspaceDirectoryURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let vscodeDirectoryURL = workspaceDirectoryURL.appendingPathComponent(".vscode", isDirectory: true)
        try fileManager.createDirectory(at: vscodeDirectoryURL, withIntermediateDirectories: true)
        let settingsURL = vscodeDirectoryURL.appendingPathComponent("settings.json", isDirectory: false)

        let existingData: Data?
        if fileManager.fileExists(atPath: settingsURL.path) {
            existingData = try Data(contentsOf: settingsURL)
        } else {
            existingData = nil
        }

        let updated = try Self.upsertVSCodeWorkspaceDebugSettingsData(existingData: existingData)
        try updated.write(to: settingsURL, options: .atomic)
        return settingsURL
    }

    func launchBrowserForVSCodeDebug(port: Int) throws -> String {
        guard let browserURL = preferredVSCodeDebugBrowserURL() else {
            throw VSCodeBrowserDebugSetupError.browserNotFound
        }

        let fileManager = FileManager.default
        let appSupportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let profileDirectory = appSupportRoot
            .appendingPathComponent("idx0", isDirectory: true)
            .appendingPathComponent("vscode-browser-debug", isDirectory: true)
        try fileManager.createDirectory(at: profileDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-n",
            "-a",
            browserURL.path,
            "--args",
            "--remote-debugging-port=\(port)",
            "--user-data-dir=\(profileDirectory.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "about:blank"
        ]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw VSCodeBrowserDebugSetupError.browserLaunchFailed(error.localizedDescription)
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = String(
                decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw VSCodeBrowserDebugSetupError.browserLaunchFailed(
                stderr.isEmpty
                    ? "open exited with status \(process.terminationStatus)"
                    : stderr
            )
        }

        return browserURL.deletingPathExtension().lastPathComponent
    }

    func preferredVSCodeDebugBrowserURL() -> URL? {
        let bundleIDs = [
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "company.thebrowser.Browser",
            "com.microsoft.edgemac",
            "com.brave.Browser",
            "org.chromium.Chromium"
        ]

        for bundleID in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return url
            }
        }

        let fallbackPaths = [
            "/Applications/Google Chrome.app",
            "/Applications/Google Chrome Canary.app",
            "/Applications/Arc.app",
            "/Applications/Microsoft Edge.app",
            "/Applications/Brave Browser.app",
            "/Applications/Chromium.app"
        ]

        let fileManager = FileManager.default
        for path in fallbackPaths where fileManager.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return nil
    }

    static func upsertVSCodeBrowserAttachConfigurationData(
        existingData: Data?,
        configurationName: String,
        port: Int,
        urlFilter: String,
        webRoot: String
    ) throws -> Data {
        var root: [String: Any]
        if let existingData, !existingData.isEmpty {
            root = try decodeVSCodeLaunchDocument(from: existingData)
        } else {
            root = [:]
        }

        if root["version"] == nil {
            root["version"] = "0.2.0"
        }

        let config: [String: Any] = [
            "type": "pwa-chrome",
            "request": "attach",
            "name": configurationName,
            "port": port,
            "urlFilter": urlFilter,
            "webRoot": webRoot
        ]

        var configurations = normalizeVSCodeLaunchConfigurations(root["configurations"])
        if let existingIndex = configurations.firstIndex(where: {
            ($0["name"] as? String) == configurationName
        }) {
            var updated = configurations[existingIndex]
            for (key, value) in config {
                updated[key] = value
            }
            configurations[existingIndex] = updated
        } else {
            configurations.append(config)
        }
        root["configurations"] = configurations

        let encoded = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return encoded + Data([0x0A])
    }

    static func upsertVSCodeWorkspaceDebugSettingsData(existingData: Data?) throws -> Data {
        var root: [String: Any]
        if let existingData, !existingData.isEmpty {
            root = try decodeVSCodeLaunchDocument(from: existingData)
        } else {
            root = [:]
        }

        root["debug.javascript.debugByLinkOptions"] = "off"

        let encoded = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return encoded + Data([0x0A])
    }

    static func decodeVSCodeLaunchDocument(from data: Data) throws -> [String: Any] {
        let raw = String(decoding: data, as: UTF8.self)
        let stripped = stripJSONComments(from: raw)
        guard let parsedData = stripped.data(using: .utf8) else {
            throw VSCodeBrowserDebugSetupError.invalidLaunchJSON("Failed to decode launch.json as UTF-8.")
        }

        do {
            let json = try JSONSerialization.jsonObject(with: parsedData, options: [])
            guard let root = json as? [String: Any] else {
                throw VSCodeBrowserDebugSetupError.invalidLaunchJSON("Expected a JSON object at the root.")
            }
            return root
        } catch {
            throw VSCodeBrowserDebugSetupError.invalidLaunchJSON(error.localizedDescription)
        }
    }

    static func normalizeVSCodeLaunchConfigurations(_ value: Any?) -> [[String: Any]] {
        guard let value else { return [] }
        if let typed = value as? [[String: Any]] {
            return typed
        }
        if let untyped = value as? [Any] {
            return untyped.compactMap { $0 as? [String: Any] }
        }
        return []
    }

    static func stripJSONComments(from text: String) -> String {
        var output = String()
        var index = text.startIndex
        var isInString = false
        var isEscaped = false

        while index < text.endIndex {
            let character = text[index]

            if isInString {
                output.append(character)
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
                index = text.index(after: index)
                continue
            }

            if character == "\"" {
                isInString = true
                output.append(character)
                index = text.index(after: index)
                continue
            }

            if character == "/" {
                let nextIndex = text.index(after: index)
                if nextIndex < text.endIndex {
                    let nextCharacter = text[nextIndex]
                    if nextCharacter == "/" {
                        index = text.index(after: nextIndex)
                        while index < text.endIndex, text[index] != "\n" {
                            index = text.index(after: index)
                        }
                        continue
                    }
                    if nextCharacter == "*" {
                        index = text.index(after: nextIndex)
                        while index < text.endIndex {
                            let candidateEnd = text.index(after: index)
                            if text[index] == "*", candidateEnd < text.endIndex, text[candidateEnd] == "/" {
                                index = text.index(after: candidateEnd)
                                break
                            }
                            index = text.index(after: index)
                        }
                        continue
                    }
                }
            }

            output.append(character)
            index = text.index(after: index)
        }

        return output
    }

    func adjustWebViewZoom(_ webView: WKWebView, by delta: CGFloat) {
        let current = webView.pageZoom
        let next = max(0.5, min(3.0, current + delta))
        webView.pageZoom = next
    }

    func setLastFocusedSurface(for sessionID: UUID, surface: SessionSurfaceFocus) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        lastFocusedSurfaceBySession[sessionID] = surface
    }

    func resolveSessionTitle(
        requested: String?,
        repoPath: String?,
        branchName: String?
    ) -> String {
        if let requested {
            let cleaned = requested.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return cleaned
            }
        }

        if let repoPath {
            let repoName = URL(fileURLWithPath: repoPath).lastPathComponent
            if let branchName, !branchName.isEmpty {
                return "\(repoName): \(branchName)"
            }
            return repoName
        }

        let count = sessions.count + 1
        return "Session \(count)"
    }

    func indexOfSession(_ id: UUID) -> Int? {
        sessions.firstIndex(where: { $0.id == id })
    }

    func setStatusText(for id: UUID, text: String?) {
        guard let index = indexOfSession(id) else { return }
        if sessions[index].statusText != text {
            sessions[index].statusText = text
            persistSoon()
        }
    }

    func sortedGroupSessions(
        for group: ProjectGroup,
        lookup: [UUID: Session]
    ) -> [Session] {
        let groupedSessions = group.sessionIDs.compactMap { lookup[$0] }
        let order = Dictionary(uniqueKeysWithValues: group.sessionIDs.enumerated().map { ($0.element, $0.offset) })

        return groupedSessions.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }

            if lhs.isPinned {
                let lhsOrder = order[lhs.id] ?? .max
                let rhsOrder = order[rhs.id] ?? .max
                return lhsOrder < rhsOrder
            }

            if lhs.lastActiveAt != rhs.lastActiveAt {
                return lhs.lastActiveAt > rhs.lastActiveAt
            }

            let lhsOrder = order[lhs.id] ?? .max
            let rhsOrder = order[rhs.id] ?? .max
            return lhsOrder < rhsOrder
        }
    }

    func applyLaunchDirectory(_ launchDirectory: String, to sessionID: UUID) {
        guard let index = indexOfSession(sessionID) else { return }
        sessions[index].lastLaunchCwd = launchDirectory
        sessions[index].lastKnownCwd = launchDirectory
        if let manifest = sessions[index].lastLaunchManifest {
            sessions[index].lastLaunchManifest = SessionLaunchManifest(
                sessionID: manifest.sessionID,
                cwd: normalizePath(launchDirectory) ?? launchDirectory,
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
        if !sessions[index].hasCustomTitle {
            let suggested = URL(fileURLWithPath: launchDirectory).lastPathComponent
            if !suggested.isEmpty {
                sessions[index].title = suggested
            }
        }
        synchronizeProjectGroups()
        persistSoon()
    }

    func reconcileActiveState() {
        attentionCenter.replaceItems(attentionItems)
        for index in sessions.indices {
            if sessions[index].id == selectedSessionID {
                sessions[index].attentionState = .active
            } else if unresolvedReason(for: sessions[index].id) != nil {
                sessions[index].attentionState = .needsAttention
            } else if sessions[index].attentionState == .active || sessions[index].attentionState == .needsAttention {
                sessions[index].attentionState = .normal
            }
        }
    }

    func synchronizeProjectGroups() {
        projectService.replaceGroups(projectGroups)
        projectService.synchronize(
            sessions: &sessions,
            normalizePath: { self.normalizePath($0) },
            projectTitle: { self.projectTitle(for: $0) }
        )
        for index in sessions.indices {
            if let manifest = sessions[index].lastLaunchManifest {
                let projectID = sessions[index].projectID?.uuidString
                if manifest.projectID != projectID || manifest.ipcSocketPath != ipcSocketPath {
                    sessions[index].lastLaunchManifest = SessionLaunchManifest(
                        sessionID: manifest.sessionID,
                        cwd: manifest.cwd,
                        shellPath: manifest.shellPath,
                        repoPath: manifest.repoPath,
                        worktreePath: manifest.worktreePath,
                        sandboxProfile: manifest.sandboxProfile,
                        networkPolicy: manifest.networkPolicy,
                        tempRoot: manifest.tempRoot,
                        environment: manifest.environment,
                        projectID: projectID,
                        ipcSocketPath: ipcSocketPath
                    )
                }
            }
        }
        projectGroups = projectService.groups
    }

    func projectTitle(for session: Session) -> String {
        if let repoPath = normalizePath(session.repoPath) {
            return URL(fileURLWithPath: repoPath).lastPathComponent
        }

        let fallback = session.lastKnownCwd ?? session.lastLaunchCwd
        let base = URL(fileURLWithPath: fallback).lastPathComponent
        return base.isEmpty ? "General" : base
    }

    func recordAttention(sessionID: UUID, reason: AttentionReason, message: String?) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }

        attentionCenter.replaceItems(attentionItems)
        attentionCenter.record(sessionID: sessionID, reason: reason, message: message)
        attentionItems = attentionCenter.items
        postNativeNotificationIfNeeded(sessionID: sessionID, reason: reason, message: message)

        if selectedSessionID == sessionID {
            resolveAttentionOnVisit(sessionID: sessionID)
        } else {
            synchronizeAttentionState()
            persistSoon()
        }
    }

    func resolveAttentionIfNotError(sessionID: UUID) {
        attentionCenter.replaceItems(attentionItems)
        let changed = attentionCenter.resolveIfNotError(sessionID: sessionID)
        attentionItems = attentionCenter.items
        synchronizeAttentionState()
        if changed {
            persistSoon()
        }
    }

    func resolveAttentionOnVisit(sessionID: UUID) {
        attentionCenter.replaceItems(attentionItems)
        let changed = attentionCenter.resolveOnVisit(sessionID: sessionID)
        attentionItems = attentionCenter.items

        synchronizeAttentionState()
        if changed {
            persistSoon()
            return
        }
        persistSoon()
    }

    func synchronizeAttentionState() {
        attentionCenter.replaceItems(attentionItems)
        for index in sessions.indices {
            let reason = attentionCenter.unresolvedReason(for: sessions[index].id)
            sessions[index].latestAttentionReason = reason
            if sessions[index].id == selectedSessionID {
                sessions[index].attentionState = .active
            } else if reason != nil {
                sessions[index].attentionState = .needsAttention
            } else if sessions[index].attentionState == .needsAttention {
                sessions[index].attentionState = .normal
            }
        }
    }

    func unresolvedReason(for sessionID: UUID) -> AttentionReason? {
        return attentionCenter.unresolvedReason(for: sessionID)
    }

    func postNativeNotificationIfNeeded(sessionID: UUID, reason: AttentionReason, message: String?) {
        guard !isRunningTests else { return }
        guard !NSApp.isActive else { return }
        guard reason == .error || reason == .needsInput || reason == .completed else { return }
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }

        let key = "\(sessionID.uuidString)|\(reason.rawValue)"
        let now = Date()
        if let previous = lastNotificationSentAt[key], now.timeIntervalSince(previous) < 20 {
            return
        }
        lastNotificationSentAt[key] = now

        requestNotificationAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = session.title
        content.body = message ?? defaultNotificationMessage(for: reason)
        content.sound = .default
        content.userInfo = [
            "sessionID": sessionID.uuidString,
            "reason": reason.rawValue
        ]

        let request = UNNotificationRequest(
            identifier: "idx0.\(sessionID.uuidString).\(reason.rawValue).\(Int(now.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        notificationCenter.add(request)
    }

    func defaultNotificationMessage(for reason: AttentionReason) -> String {
        switch reason {
        case .error:
            return "Session reported an error."
        case .needsInput:
            return "Session is waiting for input."
        case .completed:
            return "Session completed."
        case .notification:
            return "Session notification."
        }
    }

    func requestNotificationAuthorizationIfNeeded() {
        guard !notificationAuthorizationRequested else { return }
        notificationAuthorizationRequested = true
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private struct PersistenceWriteSnapshot {
        let shouldPersistSessionState: Bool
        let settings: AppSettings
        let sessionsPayload: SessionsFilePayload?
        let projectsPayload: ProjectsFilePayload?
        let inboxPayload: InboxFilePayload?
        let tileStatePayload: PersistedTileStateFilePayload?
        let shouldClearTileState: Bool
    }

    func persistSoon() {
        persistenceDebouncer.cancel()
        persistenceDebouncer.schedule {
            self.persistNowAsync()
        }
    }

    func persistNow() {
        persistenceDebouncer.cancel()
        let snapshot = capturePersistenceSnapshot()
        performPersistenceWrite(snapshot: snapshot, synchronously: true)
    }

    private func persistNowAsync() {
        let snapshot = capturePersistenceSnapshot()
        performPersistenceWrite(snapshot: snapshot, synchronously: false)
    }

    private func capturePersistenceSnapshot() -> PersistenceWriteSnapshot {
        let currentSettings = settings

        guard shouldPersistSessionState else {
            return PersistenceWriteSnapshot(
                shouldPersistSessionState: false,
                settings: currentSettings,
                sessionsPayload: nil,
                projectsPayload: nil,
                inboxPayload: nil,
                tileStatePayload: nil,
                shouldClearTileState: currentSettings.cleanupOnClose
            )
        }

        let sessionsPayload = SessionsFilePayload(
            schemaVersion: PersistenceSchema.currentVersion,
            selectedSessionID: selectedSessionID,
            sessions: sessions
        )
        let projectsPayload = ProjectsFilePayload(
            schemaVersion: PersistenceSchema.currentVersion,
            groups: projectGroups
        )
        let inboxPayload = InboxFilePayload(
            schemaVersion: PersistenceSchema.currentVersion,
            items: attentionItems
        )

        let tileStatePayload: PersistedTileStateFilePayload? = {
            guard !currentSettings.cleanupOnClose else { return nil }

            let validSessionIDs = Set(sessions.map(\.id))
            var statesBySession: [UUID: PersistedSessionTileState] = [:]

            for sessionID in validSessionIDs {
                guard let tabs = tabsBySession[sessionID], !tabs.isEmpty else { continue }

                let persistedTabs = tabs.map(persistedTab(from:))
                let selectedTabID = selectedTabIDBySession[sessionID]
                let persistedLayout = niriLayoutsBySession[sessionID].map(persistedNiriLayout(from:))

                statesBySession[sessionID] = PersistedSessionTileState(
                    tabs: persistedTabs,
                    selectedTabID: selectedTabID,
                    niriLayout: persistedLayout
                )
            }

            guard !statesBySession.isEmpty else { return nil }
            return PersistedTileStateFilePayload(
                schemaVersion: TileStatePersistenceSchema.currentVersion,
                sessions: statesBySession
            )
        }()

        return PersistenceWriteSnapshot(
            shouldPersistSessionState: true,
            settings: currentSettings,
            sessionsPayload: sessionsPayload,
            projectsPayload: projectsPayload,
            inboxPayload: inboxPayload,
            tileStatePayload: tileStatePayload,
            shouldClearTileState: currentSettings.cleanupOnClose || tileStatePayload == nil
        )
    }

    private func performPersistenceWrite(snapshot: PersistenceWriteSnapshot, synchronously: Bool) {
        let sessionStore = self.sessionStore
        let projectStore = self.projectStore
        let inboxStore = self.inboxStore
        let settingsStore = self.settingsStore
        let tileStateFileURL = self.tileStateFileURL

        let writeBlock = {
            do {
                if snapshot.shouldPersistSessionState {
                    guard let sessionsPayload = snapshot.sessionsPayload,
                          let projectsPayload = snapshot.projectsPayload,
                          let inboxPayload = snapshot.inboxPayload
                    else {
                        return
                    }
                    try sessionStore.save(payload: sessionsPayload)
                    try projectStore.save(payload: projectsPayload)
                    try inboxStore.save(payload: inboxPayload)
                }

                try settingsStore.save(snapshot.settings)

                if snapshot.shouldClearTileState {
                    Self.removePersistedTileStateFile(at: tileStateFileURL)
                } else if let tileStatePayload = snapshot.tileStatePayload {
                    try Self.writeTileStatePayload(tileStatePayload, to: tileStateFileURL)
                }
            } catch {
                Logger.error("Persist failed: \(error.localizedDescription)")
            }
        }

        if synchronously {
            persistenceQueue.sync {
                writeBlock()
            }
        } else {
            persistenceQueue.async(execute: DispatchWorkItem(block: writeBlock))
        }
    }

    private static func writeTileStatePayload(_ payload: PersistedTileStateFilePayload, to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func removePersistedTileStateFile(at fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
