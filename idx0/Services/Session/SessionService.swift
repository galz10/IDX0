import AppKit
import Foundation
import SwiftUI
import UserNotifications
import WebKit

@MainActor
final class SessionService: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var projectGroups: [ProjectGroup] = []
    @Published var attentionItems: [AttentionItem] = []
    @Published var selectedSessionID: UUID?
    @Published var settings: AppSettings
    @Published var pendingWorktreeCleanupNotice: WorktreeCleanupNotice?
    @Published var pendingWorktreeDeletePrompt: WorktreeDeletePrompt?
    @Published var pendingWorktreeInspector: WorktreeInspectorRequest?

    let sessionStore: SessionStore
    let projectStore: ProjectStore
    let inboxStore: InboxStore
    let settingsStore: SettingsStore
    nonisolated(unsafe) let worktreeService: WorktreeServiceProtocol
    let shellHealthService = ShellIntegrationHealthService()
    let host: GhosttyAppHost
    let launcherDirectory: URL
    let launcherClient: any SessionLauncherProtocol
    let sandboxExecutablePath = "/usr/bin/sandbox-exec"
    var shellPool: ShellPoolService?
    let notificationCenter = UNUserNotificationCenter.current()
    let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    let ipcSocketPath: String
    let shouldPersistSessionState: Bool
    let tileStateFileURL: URL
    let tileStateEncoder: JSONEncoder
    let tileStateDecoder: JSONDecoder

    var runtimeControllers: [UUID: TerminalSessionController] = [:]
    var ownerSessionIDByControllerID: [UUID: UUID] = [:]
    var pendingPaneControllerEnsureIDs: Set<UUID> = []
    var launchStartedAtByControllerID: [UUID: Date] = [:]
    var launchUsedWrapperByControllerID: [UUID: Bool] = [:]
    var wrapperStartupProbeTaskByControllerID: [UUID: Task<Void, Never>] = [:]
    var launchInitializedControllerIDs: Set<UUID> = []
    var wrapperFallbackAppliedBySessionID: Set<UUID> = []
    let wrapperStartupProbeDelayNanoseconds: UInt64 = 3_000_000_000
    let wrapperRetryWindowSeconds: TimeInterval = 12.0
    var browserControllers: [UUID: SessionBrowserController] = [:]
    var niriBrowserControllersByItemID: [UUID: SessionBrowserController] = [:]
    var niriAppControllersByItemID: [UUID: [String: any NiriAppTileRuntimeControlling]] = [:]
    let t3BuildCoordinator = T3BuildCoordinator()
    let t3SnapshotManager = T3StateSnapshotManager()
    let vscodeProvisioner = OpenVSCodeProvisioner()
    let vscodeSnapshotManager = VSCodeStateSnapshotManager()
    let openCodeSnapshotManager = OpenCodeStateSnapshotManager()
    let niriAppRegistry: NiriAppRegistry
    let vscodeBrowserDebugPort = 9222
    let vscodeBrowserDebugConfigName = "Attach Chrome (idx-web)"
    let vscodeBrowserDebugURLFilter = "*://*/*"
    var lastFocusedSurfaceBySession: [UUID: SessionSurfaceFocus] = [:]
    var projectService = ProjectService()
    var attentionCenter = AttentionCenter()
    var notificationAuthorizationRequested = false
    var lastNotificationSentAt: [String: Date] = [:]
    let persistenceDebouncer = Debouncer(delay: 0.2)
    let restoreCoordinator = SessionRestoreCoordinator()

    @Published var tabsBySession: [UUID: [SessionTerminalTab]] = [:]
    @Published var selectedTabIDBySession: [UUID: UUID] = [:]
    @Published var niriLayoutsBySession: [UUID: NiriCanvasLayout] = [:]
    @Published var niriFocusedTileZoomItemIDBySession: [UUID: UUID] = [:]

    /// Pane tree per session. nil means single pane (no splits).
    var paneTrees: [UUID: PaneNode] = [:]
    /// The focused pane controller ID within a session (for multi-pane).
    @Published var focusedPaneControllerID: [UUID: UUID] = [:]

    var onSessionCreated: ((Session) -> Void)?
    var onSessionClosed: ((UUID) -> Void)?
    var onSessionLaunched: ((UUID) -> Void)?
    var onSessionCompleted: ((UUID, String?) -> Void)?
    var onSessionErrored: ((UUID, String?) -> Void)?
    var onSessionNeedsInput: ((UUID, String?) -> Void)?
    var onSessionFocused: ((UUID) -> Void)?

    init(
        sessionStore: SessionStore,
        projectStore: ProjectStore,
        inboxStore: InboxStore,
        settingsStore: SettingsStore,
        worktreeService: WorktreeServiceProtocol,
        launcherDirectory: URL? = nil,
        ipcSocketPath: String? = nil,
        tileStateFileURL: URL? = nil,
        niriAppRegistry: NiriAppRegistry = .shared,
        host: GhosttyAppHost = .shared
    ) {
        self.sessionStore = sessionStore
        self.projectStore = projectStore
        self.inboxStore = inboxStore
        self.settingsStore = settingsStore
        self.worktreeService = worktreeService
        self.host = host
        self.launcherDirectory = launcherDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("idx0-launchers", isDirectory: true)
        self.launcherClient = SessionLauncherClient(
            launcherDirectory: self.launcherDirectory,
            sandboxExecutablePath: "/usr/bin/sandbox-exec"
        )
        self.ipcSocketPath = ipcSocketPath ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("idx0", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("idx0.sock", isDirectory: false)
            .path ?? "/tmp/idx0.sock"
        self.tileStateFileURL = tileStateFileURL
            ?? settingsStore.storageURL
                .deletingLastPathComponent()
                .appendingPathComponent("tile-state.json", isDirectory: false)

        let tileStateEncoder = JSONEncoder()
        tileStateEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.tileStateEncoder = tileStateEncoder

        self.tileStateDecoder = JSONDecoder()
        self.niriAppRegistry = niriAppRegistry
        self.settings = settingsStore.load()

        try? FileManager.default.createDirectory(at: self.launcherDirectory, withIntermediateDirectories: true)

        let sessionsPayload: SessionsFilePayload
        let shouldPersistSessionState: Bool
        do {
            sessionsPayload = try sessionStore.load()
            shouldPersistSessionState = true
        } catch SessionStoreError.unsupportedSchemaVersion(let version) {
            Logger.error("Unsupported sessions schema version \(version). Session persistence disabled to avoid overwriting existing data.")
            sessionsPayload = SessionsFilePayload()
            shouldPersistSessionState = false
        } catch {
            Logger.error("Failed to load sessions payload: \(error.localizedDescription)")
            sessionsPayload = SessionsFilePayload()
            shouldPersistSessionState = true
        }
        self.shouldPersistSessionState = shouldPersistSessionState
        self.sessions = sessionsPayload.sessions.map { session in
            var normalized = session
            // Agent activity is runtime-only and can become stale across launches.
            normalized.agentActivity = nil
            return normalized
        }

        if let selected = sessionsPayload.selectedSessionID,
           sessionsPayload.sessions.contains(where: { $0.id == selected }) {
            self.selectedSessionID = selected
        } else {
            self.selectedSessionID = nil
        }

        let projectsPayload = (try? projectStore.load()) ?? ProjectsFilePayload()
        self.projectService = ProjectService(groups: projectsPayload.groups)
        self.projectGroups = projectService.groups

        let inboxPayload = (try? inboxStore.load()) ?? InboxFilePayload()
        self.attentionCenter = AttentionCenter(items: inboxPayload.items)
        self.attentionItems = attentionCenter.items

        if selectedSessionID == nil, let first = sessions.first {
            selectedSessionID = first.id
        }

        registerDefaultNiriApps()
        restorePersistedTileStateIfNeeded()

        for session in sessions {
            ensureTabState(for: session.id, defaultRootControllerID: session.id)
        }

        synchronizeProjectGroups()
        synchronizeAttentionState()
        installGhosttyCallbacks()
        reconcileActiveState()
        applyRestoreBehaviorOnLaunch()
        if let selectedSessionID {
            _ = ensureController(for: selectedSessionID)
        }
        persistSoon()
    }

    var selectedSession: Session? {
        guard let selectedSessionID else { return nil }
        return sessions.first(where: { $0.id == selectedSessionID })
    }

    var selectedController: TerminalSessionController? {
        guard let selectedSessionID else { return nil }
        return controller(for: selectedSessionID)
    }

    var registeredNiriApps: [NiriAppDescriptor] {
        niriAppRegistry.orderedDescriptors
    }

    var visibleNiriApps: [NiriAppDescriptor] {
        niriAppRegistry.visibleDescriptors
    }

    func niriAppDescriptor(for appID: String) -> NiriAppDescriptor? {
        niriAppRegistry.descriptor(for: appID)
    }

    var unresolvedAttentionItems: [AttentionItem] {
        attentionItems
            .filter { !$0.isResolved }
            .sorted { lhs, rhs in
                if lhs.reason.urgencyRank != rhs.reason.urgencyRank {
                    return lhs.reason.urgencyRank < rhs.reason.urgencyRank
                }
                return lhs.createdAt > rhs.createdAt
            }
    }

    private func registerDefaultNiriApps() {
        niriAppRegistry.register(contentsOf: [
            NiriAppDescriptor(
                id: NiriAppID.t3Code,
                displayName: "T3 Code",
                icon: "chevron.left.forwardslash.chevron.right",
                iconImageName: "icon-t3code",
                menuSubtitle: "Run reconstructed T3 in-canvas",
                isVisibleInMenus: true,
                supportsWebZoomPersistence: false,
                startTile: { service, sessionID in
                    service.niriAddSingletonAppRight(in: sessionID, appID: NiriAppID.t3Code)
                },
                retryTile: { service, sessionID, itemID in
                    service.retryNiriAppController(sessionID: sessionID, itemID: itemID, appID: NiriAppID.t3Code)
                },
                stopTile: { service, itemID in
                    service.stopNiriAppController(itemID: itemID, appID: NiriAppID.t3Code)
                },
                ensureController: { service, sessionID, itemID in
                    service.makeNiriT3Controller(sessionID: sessionID, itemID: itemID)
                },
                makeTileView: { service, sessionID, itemID in
                    guard let controller: T3TileController = service.niriAppController(
                        for: sessionID,
                        itemID: itemID,
                        appID: NiriAppID.t3Code,
                        as: T3TileController.self
                    ) else {
                        return AnyView(service.niriMissingAppTile(title: "T3 Code Unavailable"))
                    }
                    return AnyView(
                        NiriT3Tile(sessionID: sessionID, itemID: itemID, controller: controller)
                            .environmentObject(service)
                    )
                },
                cleanupSessionArtifacts: { service, sessionID in
                    service.t3SnapshotManager.removeSessionSnapshot(paths: T3RuntimePaths(sessionID: sessionID))
                }
            ),
            NiriAppDescriptor(
                id: NiriAppID.vscode,
                displayName: "VS Code",
                icon: "chevron.left.forwardslash.chevron.right.square",
                iconImageName: "icon-vscode",
                menuSubtitle: "Run embedded VS Code editor",
                isVisibleInMenus: true,
                supportsWebZoomPersistence: true,
                startTile: { service, sessionID in
                    service.niriAddSingletonAppRight(in: sessionID, appID: NiriAppID.vscode)
                },
                retryTile: { service, sessionID, itemID in
                    service.retryNiriAppController(sessionID: sessionID, itemID: itemID, appID: NiriAppID.vscode)
                },
                stopTile: { service, itemID in
                    service.stopNiriAppController(itemID: itemID, appID: NiriAppID.vscode)
                },
                ensureController: { service, sessionID, itemID in
                    service.makeNiriVSCodeController(sessionID: sessionID, itemID: itemID)
                },
                makeTileView: { service, sessionID, itemID in
                    guard let controller: VSCodeTileController = service.niriAppController(
                        for: sessionID,
                        itemID: itemID,
                        appID: NiriAppID.vscode,
                        as: VSCodeTileController.self
                    ) else {
                        return AnyView(service.niriMissingAppTile(title: "VS Code Unavailable"))
                    }
                    return AnyView(
                        NiriVSCodeTile(sessionID: sessionID, itemID: itemID, controller: controller)
                            .environmentObject(service)
                    )
                },
                cleanupSessionArtifacts: { service, sessionID in
                    service.vscodeSnapshotManager.removeSessionState(paths: VSCodeRuntimePaths(sessionID: sessionID))
                }
            ),
            NiriAppDescriptor(
                id: NiriAppID.openCode,
                displayName: "OpenCode",
                icon: "chevron.left.forwardslash.chevron.right",
                iconImageName: "icon-opencode",
                menuSubtitle: "Run embedded OpenCode desktop",
                isVisibleInMenus: true,
                supportsWebZoomPersistence: true,
                startTile: { service, sessionID in
                    service.niriAddSingletonAppRight(in: sessionID, appID: NiriAppID.openCode)
                },
                retryTile: { service, sessionID, itemID in
                    service.retryNiriAppController(sessionID: sessionID, itemID: itemID, appID: NiriAppID.openCode)
                },
                stopTile: { service, itemID in
                    service.stopNiriAppController(itemID: itemID, appID: NiriAppID.openCode)
                },
                ensureController: { service, sessionID, itemID in
                    service.makeNiriOpenCodeController(sessionID: sessionID, itemID: itemID)
                },
                makeTileView: { service, sessionID, itemID in
                    guard let controller: OpenCodeTileController = service.niriAppController(
                        for: sessionID,
                        itemID: itemID,
                        appID: NiriAppID.openCode,
                        as: OpenCodeTileController.self
                    ) else {
                        return AnyView(service.niriMissingAppTile(title: "OpenCode Unavailable"))
                    }
                    return AnyView(
                        NiriOpenCodeTile(sessionID: sessionID, itemID: itemID, controller: controller)
                            .environmentObject(service)
                    )
                },
                cleanupSessionArtifacts: { service, sessionID in
                    service.openCodeSnapshotManager.removeSessionState(paths: OpenCodeRuntimePaths(sessionID: sessionID))
                }
            )
        ])
    }

    @ViewBuilder
    private func niriMissingAppTile(title: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.orange)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text("Tile could not be created.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var projectSections: [ProjectSessionSection] {
        let lookup = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        return projectGroups.compactMap { group in
            let groupedSessions = sortedGroupSessions(for: group, lookup: lookup)
            guard !groupedSessions.isEmpty else { return nil }
            return ProjectSessionSection(group: group, sessions: groupedSessions)
        }
    }

}
