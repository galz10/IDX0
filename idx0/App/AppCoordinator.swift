import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppCoordinator: ObservableObject {
  @Published var showingNewSessionSheet = false
  @Published var newSessionPreset: NewSessionPreset = .quick
  @Published var showingRenameSessionSheet = false
  @Published var showingCommandPalette = false
  @Published var showingQuickSwitch = false
  @Published var showingKeyboardShortcuts = false
  @Published var showingNiriOnboarding = false
  @Published var showingCheckpoints = false
  @Published var showingDiffOverlay = false
  @Published var showingSettings = false
  @Published var niriQuickAddRequestSessionID: UUID?
  @Published var renameSessionID: UUID?
  @Published var renameDraftTitle = ""

  let paths: FileSystemPaths
  let sessionService: SessionService
  let workflowService: WorkflowService
  let terminalMonitor = TerminalMonitorService()
  let autoCheckpointService: AutoCheckpointService
  let shellPool = ShellPoolService()
  let appUpdateService: AppUpdateService

  private var ipcServer: IPCServer?
  private let ipcCommandRouter: IPCCommandRouter
  private var gitMonitor: GitMonitor?
  private var localKeyMonitor: Any?
  private let shortcutDispatcher = ShortcutDispatcher()
  let shortcutCommandDispatcher = ShortcutCommandDispatcher()

  init() {
    do {
      let paths = try BootstrapCoordinator.makePaths()
      self.paths = paths

      let sessionStore = SessionStore(url: paths.sessionsFile)
      let projectStore = ProjectStore(url: paths.projectsFile)
      let inboxStore = InboxStore(url: paths.inboxFile)
      let settingsStore = SettingsStore(url: paths.settingsFile)
      // Write theme config before GhosttyAppHost.shared initializes
      let earlySettings = settingsStore.load()
      GhosttyAppHost.writeThemeConfig(themeID: earlySettings.terminalThemeID)

      let gitService = GitService()
      let worktreeService = WorktreeService(gitService: gitService, paths: paths)
      let launcherRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("idx0-launchers", isDirectory: true)

      sessionService = SessionService(
        sessionStore: sessionStore,
        projectStore: projectStore,
        inboxStore: inboxStore,
        settingsStore: settingsStore,
        worktreeService: worktreeService,
        launcherDirectory: launcherRoot,
        ipcSocketPath: paths.runDirectory.appendingPathComponent("idx0.sock", isDirectory: false).path,
        host: .shared
      )

      workflowService = WorkflowService(
        sessionService: sessionService,
        checkpointStore: CheckpointStore(url: paths.checkpointsFile),
        handoffStore: HandoffStore(url: paths.handoffsFile),
        reviewStore: ReviewStore(url: paths.reviewsFile),
        approvalStore: ApprovalStore(url: paths.approvalsFile),
        queueStore: QueueStore(url: paths.queueFile),
        timelineStore: TimelineStore(url: paths.timelineFile),
        layoutStore: LayoutStore(url: paths.layoutFile),
        agentEventStore: AgentEventStore(url: paths.agentEventsFile),
        legacyAttentionItems: sessionService.attentionItems
      )
      ipcCommandRouter = IPCCommandRouter(
        sessionService: sessionService,
        workflowService: workflowService
      )

      autoCheckpointService = AutoCheckpointService(
        gitService: gitService,
        storageURL: paths.appSupportDirectory.appendingPathComponent("auto-checkpoints.json", isDirectory: false)
      )
      let environmentProvider = ProcessEnvironmentProvider()
      let updateDriver = SparkleUpdateDriver(environment: environmentProvider)
      let sessionServiceForUpdates = sessionService
      appUpdateService = AppUpdateService(
        driver: updateDriver,
        scheduler: TimerUpdateScheduler(),
        versionProvider: BundleAppVersionProvider(),
        environment: environmentProvider,
        autoCheckEnabledProvider: {
          sessionServiceForUpdates.settings.autoCheckForUpdates
        }
      )

      // Configure terminal monitor
      terminalMonitor.configure(
        host: .shared,
        surfaceProvider: { [weak self] sessionID in
          self?.sessionService.controller(for: sessionID)?.terminalSurface
        },
        sessionInfoProvider: { [weak self] sessionID in
          guard let self, let session = sessionService.sessions.first(where: { $0.id == sessionID }) else {
            return nil
          }
          return (title: session.title, isFocused: sessionService.selectedSessionID == sessionID)
        }
      )

      // Terminal monitor callbacks
      terminalMonitor.onStateChanged = { [weak self] sessionID, result in
        guard let self else { return }
        let hasDetectedAgent = result.hasDetectedAgent
        // Update session's agent activity from scan result
        let activity: AgentActivity? = {
          guard hasDetectedAgent else { return nil }
          switch result.state {
          case .thinking, .working:
            return .active(description: result.stateDescription ?? "Working...")
          case .waitingForInput:
            return .waiting(description: result.stateDescription ?? "Waiting for input")
          case .completed:
            return .completed(description: result.stateDescription ?? "Finished")
          case .error:
            return .error(description: result.stateDescription ?? "Error")
          case .idle:
            return nil
          }
        }()
        sessionService.setAgentActivity(for: sessionID, activity: activity)

        // Fetch diff stats on completion
        if hasDetectedAgent, result.state == .completed {
          fetchDiffStats(for: sessionID)
        }

        // Clear diff stats when agent starts working again
        if hasDetectedAgent, result.state == .thinking || result.state == .working {
          sessionService.setDiffStat(for: sessionID, stat: nil)
        }
      }

      // Auto-checkpoint when agent starts
      terminalMonitor.onAgentStarted = { [weak self] sessionID in
        guard let self else { return }
        guard let session = sessionService.sessions.first(where: { $0.id == sessionID }) else { return }
        let path = session.worktreePath ?? session.repoPath
        guard let path else { return }
        Task {
          await self.autoCheckpointService.createCheckpoint(sessionID: sessionID, repoPath: path)
        }
      }

      terminalMonitor.startMonitoring()

      // Track existing sessions for monitoring
      for session in sessionService.sessions {
        terminalMonitor.trackSession(session.id)
      }

      sessionService.onSessionCreated = { [weak workflowService = self.workflowService, weak terminalMonitor = self.terminalMonitor] session in
        workflowService?.recordSessionCreated(session)
        terminalMonitor?.trackSession(session.id)
      }
      sessionService.onSessionLaunched = { [weak workflowService = self.workflowService] sessionID in
        workflowService?.recordSessionLaunched(sessionID)
      }
      sessionService.onSessionClosed = { [weak workflowService = self.workflowService, weak terminalMonitor = self.terminalMonitor, weak autoCheckpointService = self.autoCheckpointService] sessionID in
        workflowService?.recordSessionClosed(sessionID)
        terminalMonitor?.untrackSession(sessionID)
        autoCheckpointService?.removeCheckpoints(for: sessionID)
      }
      sessionService.onSessionCompleted = { [weak workflowService = self.workflowService] sessionID, message in
        workflowService?.recordSessionCompleted(sessionID, message: message)
      }
      sessionService.onSessionErrored = { [weak workflowService = self.workflowService] sessionID, message in
        workflowService?.recordSessionError(sessionID, message: message)
      }
      sessionService.onSessionNeedsInput = { [weak workflowService = self.workflowService, weak terminalMonitor = self.terminalMonitor] sessionID, message in
        workflowService?.recordSessionNeedsInput(sessionID, message: message)
        terminalMonitor?.notifyActivity(for: sessionID)
      }
      sessionService.onSessionFocused = { [weak workflowService = self.workflowService] sessionID in
        workflowService?.resolveApprovalItems(for: sessionID)
      }

      let socketPath = paths.runDirectory.appendingPathComponent("idx0.sock", isDirectory: false).path
      let server = IPCServer(
        socketPath: socketPath,
        handler: { [weak self] request in
          self?.handleIPCRequestFromBackground(request) ?? IPCResponse(success: false, message: "App unavailable", data: nil)
        }
      )
      ipcServer = server
      server.start()

      let monitor = GitMonitor(
        sessionService: sessionService,
        workflowService: workflowService
      )
      gitMonitor = monitor
      monitor.start()

      // Pre-warm shell pool and launcher scripts in background
      shellPool.warmUp(preferredShell: sessionService.settings.preferredShellPath)
      sessionService.prewarmLauncherScripts()
      sessionService.shellPool = shellPool
      workflowService.setShellPool(shellPool)
      installLocalKeyMonitor()
    } catch {
      fatalError("Failed to initialize app coordinator: \(error)")
    }
  }

  func prepareForTermination() {
    terminalMonitor.stopMonitoring()
    gitMonitor?.stop()
    ipcServer?.stop()
    if let localKeyMonitor {
      NSEvent.removeMonitor(localKeyMonitor)
      self.localKeyMonitor = nil
    }
    workflowService.prepareForTermination()
    sessionService.prepareForTermination()
  }

  private func installLocalKeyMonitor() {
    localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return event }
      return handleLocalKeyEvent(event)
    }
  }

  private func handleLocalKeyEvent(_ event: NSEvent) -> NSEvent? {
    if handleInlineSettingsEscape(event) {
      return nil
    }
    guard !isEditableTextInputFocused else { return event }
    if handleNiriOverviewArrowKeyNavigation(event) {
      return nil
    }
    guard let action = shortcutDispatcher.resolveAction(for: event, settings: sessionService.settings) else {
      return event
    }
    guard shortcutCommandDispatcher.perform(action, coordinator: self) else { return event }
    return nil
  }

  private func handleInlineSettingsEscape(_ event: NSEvent) -> Bool {
    guard showingSettings else { return false }
    guard event.keyCode == 53 else { return false } // Escape
    let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
    guard modifiers.isEmpty else { return false }
    showingSettings = false
    return true
  }

  private func handleNiriOverviewArrowKeyNavigation(_ event: NSEvent) -> Bool {
    guard sessionService.settings.niriCanvasEnabled,
          let selectedSessionID = sessionService.selectedSessionID
    else {
      return false
    }

    let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
    guard modifiers.isEmpty else { return false }

    // Escape exits focused-tile zoom mode.
    if event.keyCode == 53,
       sessionService.niriFocusedTileZoomItemID(for: selectedSessionID) != nil
    {
      sessionService.clearNiriFocusedTileZoom(sessionID: selectedSessionID)
      return true
    }

    let layout = sessionService.niriLayout(for: selectedSessionID)
    guard layout.isOverviewOpen else { return false }

    // Escape exits overview mode.
    if event.keyCode == 53 {
      sessionService.toggleNiriOverview(sessionID: selectedSessionID)
      return true
    }

    guard let key = ShortcutKey.from(event: event) else { return false }
    switch key {
    case .upArrow:
      sessionService.niriFocusNeighbor(sessionID: selectedSessionID, vertical: -1)
      return true
    case .downArrow:
      sessionService.niriFocusNeighbor(sessionID: selectedSessionID, vertical: 1)
      return true
    case .leftArrow:
      sessionService.niriFocusNeighbor(sessionID: selectedSessionID, horizontal: -1)
      return true
    case .rightArrow:
      sessionService.niriFocusNeighbor(sessionID: selectedSessionID, horizontal: 1)
      return true
    case .returnKey:
      sessionService.toggleNiriOverview(sessionID: selectedSessionID)
      return true
    default:
      return false
    }
  }

  private var isEditableTextInputFocused: Bool {
    guard let firstResponder = NSApp.keyWindow?.firstResponder else {
      return false
    }
    guard let textView = firstResponder as? NSTextView else {
      return false
    }
    return textView.isEditable
  }

  func presentRenameSessionSheet(session: Session) {
    renameSessionID = session.id
    renameDraftTitle = session.title
    showingRenameSessionSheet = true
  }

  func commitRenameSession() {
    guard let renameSessionID else { return }
    sessionService.renameSession(renameSessionID, title: renameDraftTitle)
    cancelRenameSession()
  }

  func cancelRenameSession() {
    showingRenameSessionSheet = false
    renameSessionID = nil
    renameDraftTitle = ""
  }

  private nonisolated func handleIPCRequestFromBackground(_ request: IPCRequest) -> IPCResponse {
    var response = IPCResponse(success: false, message: "Coordinator unavailable", data: nil)
    DispatchQueue.main.sync {
      response = MainActor.assumeIsolated { [weak self] in
        self?.handleIPCRequest(request) ?? IPCResponse(success: false, message: "Coordinator unavailable", data: nil)
      }
    }
    return response
  }

  @MainActor
  private func handleIPCRequest(_ request: IPCRequest) -> IPCResponse {
    ipcCommandRouter.handle(request)
  }
}

enum NewSessionPreset {
  case quick
  case repo
  case worktree
}
