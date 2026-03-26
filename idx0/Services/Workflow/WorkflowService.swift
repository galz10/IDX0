import AppKit
import Combine
import Foundation
import UserNotifications

enum WorkflowServiceError: LocalizedError {
    case sessionNotFound
    case reviewNotFound
    case approvalNotFound
    case unsupportedSchemaVersion(Int)
    case duplicateEvent
    case unresolvedSession

    var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return "Session not found."
        case .reviewNotFound:
            return "Review request not found."
        case .approvalNotFound:
            return "Approval request not found."
        case .unsupportedSchemaVersion(let version):
            return "Unsupported agent event schema version: \(version)"
        case .duplicateEvent:
            return "Duplicate event ignored."
        case .unresolvedSession:
            return "Unable to resolve target session."
        }
    }
}

enum CompareInput: Hashable {
    case checkpoint(UUID)
    case session(UUID)
    case branches(repoPath: String, leftBranch: String, rightBranch: String)
}

enum HandoffTargetType: String, CaseIterable {
    case selfSession
    case otherSession
    case reviewQueue

    var displayLabel: String {
        switch self {
        case .selfSession:
            return "Self"
        case .otherSession:
            return "Other Session"
        case .reviewQueue:
            return "Review Queue"
        }
    }
}

struct HandoffComposerDraft: Identifiable, Equatable {
    let id: UUID
    var sourceSessionID: UUID
    var targetType: HandoffTargetType
    var targetSessionID: UUID?
    var checkpointID: UUID?
    var title: String
    var summary: String
    var risksText: String
    var nextActionsText: String

    init(
        id: UUID = UUID(),
        sourceSessionID: UUID,
        targetType: HandoffTargetType = .selfSession,
        targetSessionID: UUID? = nil,
        checkpointID: UUID? = nil,
        title: String = "Handoff",
        summary: String = "",
        risksText: String = "",
        nextActionsText: String = ""
    ) {
        self.id = id
        self.sourceSessionID = sourceSessionID
        self.targetType = targetType
        self.targetSessionID = targetSessionID
        self.checkpointID = checkpointID
        self.title = title
        self.summary = summary
        self.risksText = risksText
        self.nextActionsText = nextActionsText
    }
}

struct CompareResult {
    let leftTitle: String
    let leftSummary: String
    let leftSourceSessionID: UUID?
    let rightTitle: String
    let rightSummary: String
    let rightSourceSessionID: UUID?
    let leftFiles: [ChangedFileSummary]
    let rightFiles: [ChangedFileSummary]
    let leftDiffStat: DiffStat?
    let rightDiffStat: DiffStat?
    let leftTestSummary: TestSummary?
    let rightTestSummary: TestSummary?
    let overlapPaths: [String]
    let leftOnlyPaths: [String]
    let rightOnlyPaths: [String]
}

@MainActor
final class WorkflowService: ObservableObject {
    @Published var checkpoints: [Checkpoint] = []
    @Published var handoffs: [Handoff] = []
    @Published var reviews: [ReviewRequest] = []
    @Published var approvals: [ApprovalRequest] = []
    @Published var queueItems: [SupervisionQueueItem] = []
    @Published var timelineItems: [TimelineItem] = []
    @Published var layoutState: LayoutState
    @Published var vibeTools: [VibeCLITool] = []
    @Published var selectedRailSurface: WorkflowRailSurface = .checkpoints
    @Published var selectedCheckpointID: UUID?
    @Published var selectedReviewID: UUID?
    @Published var selectedHandoffID: UUID?
    @Published var comparePresetLeft: CompareInput?
    @Published var comparePresetRight: CompareInput?
    @Published var activeHandoffComposer: HandoffComposerDraft?

    let checkpointStore: CheckpointStore
    let handoffStore: HandoffStore
    let reviewStore: ReviewStore
    let approvalStore: ApprovalStore
    let queueStore: QueueStore
    let timelineStore: TimelineStore
    let layoutStore: LayoutStore
    let agentEventStore: AgentEventStore
    let sessionService: SessionService
    let queueService = SupervisionQueueService()
    let timelineService = TimelineService()
    var launchService = VibeCLILaunchService()
    let discoveryService = VibeCLIDiscoveryService()
    var shellPool: ShellPoolService?
    var shellPoolToolsCancellable: AnyCancellable?

    func setShellPool(_ pool: ShellPoolService) {
        launchService.shellPool = pool
        shellPool = pool

        shellPoolToolsCancellable?.cancel()
        shellPoolToolsCancellable = pool.$cachedTools
            .sink { [weak self] tools in
                self?.vibeTools = tools
            }

        if pool.isWarmed {
            vibeTools = pool.cachedTools
        } else {
            pool.refreshTools()
        }
    }
    let persistenceDebouncer = Debouncer(delay: 0.2)
    var cancellables: Set<AnyCancellable> = []

    var handledEventIDs: Set<UUID> = []

    init(
        sessionService: SessionService,
        checkpointStore: CheckpointStore,
        handoffStore: HandoffStore,
        reviewStore: ReviewStore,
        approvalStore: ApprovalStore,
        queueStore: QueueStore,
        timelineStore: TimelineStore,
        layoutStore: LayoutStore,
        agentEventStore: AgentEventStore,
        legacyAttentionItems: [AttentionItem]
    ) {
        self.sessionService = sessionService
        self.checkpointStore = checkpointStore
        self.handoffStore = handoffStore
        self.reviewStore = reviewStore
        self.approvalStore = approvalStore
        self.queueStore = queueStore
        self.timelineStore = timelineStore
        self.layoutStore = layoutStore
        self.agentEventStore = agentEventStore
        self.layoutState = LayoutState()

        loadAll(legacyAttentionItems: legacyAttentionItems)
        bindSessionStreams()
        synchronizeLayoutState(with: sessionService.sessions)
    }

    var unresolvedQueueItems: [SupervisionQueueItem] {
        if pruneExpiredInformationalQueueItemsIfNeeded() {
            persistSoon()
        }
        return queueService.sortedUnresolvedItems(from: queueItems)
    }

    var sortedTimelineItems: [TimelineItem] {
        timelineService.sortedLatestFirst(timelineItems)
    }

    func loadAll(legacyAttentionItems: [AttentionItem]) {
        checkpoints = (try? checkpointStore.load().checkpoints) ?? []
        handoffs = (try? handoffStore.load().handoffs) ?? []
        reviews = (try? reviewStore.load().reviews) ?? []
        approvals = (try? approvalStore.load().approvals) ?? []
        queueItems = (try? queueStore.load().items) ?? []
        timelineItems = (try? timelineStore.load().items) ?? []
        layoutState = (try? layoutStore.load().layoutState) ?? LayoutState()
        handledEventIDs = Set((try? agentEventStore.load().handledEventIDs) ?? [])
        if let selectedSessionID = sessionService.selectedSessionID,
           let savedSurface = layoutState.lastRailSurfaceBySession[selectedSessionID] {
            selectedRailSurface = savedSurface
        } else {
            selectedRailSurface = .checkpoints
        }

        selectedCheckpointID = checkpoints.sorted(by: { $0.createdAt > $1.createdAt }).first?.id
        selectedReviewID = reviews.sorted(by: { $0.createdAt > $1.createdAt }).first?.id
        selectedHandoffID = handoffs.sorted(by: { $0.createdAt > $1.createdAt }).first?.id

        if queueItems.isEmpty, !legacyAttentionItems.isEmpty {
            queueItems = legacyAttentionItems.map { legacy in
                SupervisionQueueItem(
                    id: legacy.id,
                    sessionID: legacy.sessionID,
                    relatedObjectID: nil,
                    category: mapLegacyReason(legacy.reason),
                    title: legacy.reason.displayLabel,
                    subtitle: legacy.message,
                    createdAt: legacy.createdAt,
                    isResolved: legacy.isResolved,
                    isPinned: false
                )
            }
            persistSoon()
        }
    }

    func mapLegacyReason(_ reason: AttentionReason) -> QueueItemCategory {
        switch reason {
        case .needsInput:
            return .blocked
        case .completed:
            return .completed
        case .error:
            return .error
        case .notification:
            return .informational
        }
    }

    func bindSessionStreams() {
        sessionService.$selectedSessionID
            .sink { [weak self] sessionID in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.layoutState.focusedSessionID = sessionID
                    if let sessionID,
                       let saved = self.layoutState.lastRailSurfaceBySession[sessionID] {
                        self.selectedRailSurface = saved
                    } else if sessionID != nil {
                        self.selectedRailSurface = .checkpoints
                    }
                    self.persistSoon()
                }
            }
            .store(in: &cancellables)

        sessionService.$sessions
            .sink { [weak self] sessions in
                Task { @MainActor [weak self] in
                    self?.synchronizeLayoutState(with: sessions)
                }
            }
            .store(in: &cancellables)
    }

    func synchronizeLayoutState(with sessions: [Session]) {
        let sessionIDs = Set(sessions.map(\.id))

        let pinned = sessions.filter(\.isPinned).map(\.id)
        if pinned != layoutState.pinnedSessionIDs {
            layoutState.pinnedSessionIDs = pinned
        }

        layoutState.parkedSessionIDs.removeAll { !sessionIDs.contains($0) }
        layoutState.pinnedSessionIDs.removeAll { !sessionIDs.contains($0) }
        layoutState.lastVisibleSupportingSurfaceBySession = layoutState.lastVisibleSupportingSurfaceBySession.filter { sessionIDs.contains($0.key) }
        layoutState.lastRailSurfaceBySession = layoutState.lastRailSurfaceBySession.filter { sessionIDs.contains($0.key) }

        var changedStacks = false
        var nextStacks: [SessionStack] = []
        for var stack in layoutState.stacks {
            let originalCount = stack.sessionIDs.count
            stack.sessionIDs.removeAll { !sessionIDs.contains($0) }
            if stack.sessionIDs.count != originalCount {
                changedStacks = true
            }
            if let visible = stack.visibleSessionID, !stack.sessionIDs.contains(visible) {
                stack.visibleSessionID = stack.sessionIDs.first
                changedStacks = true
            }
            if !stack.sessionIDs.isEmpty {
                nextStacks.append(stack)
            } else {
                changedStacks = true
            }
        }
        if changedStacks {
            layoutState.stacks = nextStacks
        }

        if let focused = layoutState.focusedSessionID, !sessionIDs.contains(focused) {
            layoutState.focusedSessionID = sessions.first?.id
        }

        if let selectedSessionID = sessionService.selectedSessionID,
           let savedSurface = layoutState.lastRailSurfaceBySession[selectedSessionID],
           selectedRailSurface != savedSurface {
            selectedRailSurface = savedSurface
        }

        sanitizeSelections()
        persistSoon()
    }

    func persistSoon() {
        persistenceDebouncer.cancel()
        persistenceDebouncer.schedule { [weak self] in
            self?.persistNow()
        }
    }

    func persistNow() {
        persistenceDebouncer.cancel()
        pruneExpiredInformationalQueueItemsIfNeeded()
        do {
            try checkpointStore.save(CheckpointFilePayload(checkpoints: checkpoints))
            try handoffStore.save(HandoffFilePayload(handoffs: handoffs))
            try reviewStore.save(ReviewFilePayload(reviews: reviews))
            try approvalStore.save(ApprovalFilePayload(approvals: approvals))
            try queueStore.save(QueueFilePayload(items: queueItems))
            try timelineStore.save(TimelineFilePayload(items: timelineItems))
            try layoutStore.save(LayoutFilePayload(layoutState: layoutState))
            try agentEventStore.save(AgentEventFilePayload(handledEventIDs: Array(handledEventIDs)))
        } catch {
            Logger.error("Workflow persistence failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func pruneExpiredInformationalQueueItemsIfNeeded() -> Bool {
        let pruned = queueService.pruneExpiredInformational(queueItems)
        if pruned != queueItems {
            queueItems = pruned
            return true
        }
        return false
    }

    func addNotification(
        sessionID: UUID,
        category: QueueItemCategory,
        title: String,
        subtitle: String?
    ) {
        addQueueItem(sessionID: sessionID, category: category, title: title, subtitle: subtitle, relatedObjectID: nil)
        addTimeline(sessionID: sessionID, type: .statusProgress, title: title, relatedObjectID: nil)
        persistSoon()
    }

    func addQueueItem(
        sessionID: UUID,
        category: QueueItemCategory,
        title: String,
        subtitle: String?,
        relatedObjectID: UUID?
    ) {
        queueItems.append(
            SupervisionQueueItem(
                id: UUID(),
                sessionID: sessionID,
                relatedObjectID: relatedObjectID,
                category: category,
                title: title,
                subtitle: subtitle,
                createdAt: Date(),
                isResolved: false,
                isPinned: false
            )
        )
        queueItems = queueService.pruneExpiredInformational(queueItems)
    }

    func ensureUnresolvedQueueItem(
        sessionID: UUID,
        category: QueueItemCategory,
        title: String,
        subtitle: String?,
        relatedObjectID: UUID?
    ) {
        if queueItems.contains(where: { item in
            !item.isResolved && item.relatedObjectID == relatedObjectID && item.category == category
        }) {
            return
        }
        addQueueItem(
            sessionID: sessionID,
            category: category,
            title: title,
            subtitle: subtitle,
            relatedObjectID: relatedObjectID
        )
    }

    func addTimeline(
        sessionID: UUID,
        type: TimelineItemType,
        title: String,
        relatedObjectID: UUID?
    ) {
        timelineItems = timelineService.append(
            TimelineItem(
                id: UUID(),
                sessionID: sessionID,
                createdAt: Date(),
                type: type,
                title: title,
                relatedObjectID: relatedObjectID
            ),
            to: timelineItems
        )
    }

    func makeGitSnapshot(for session: Session) async throws -> (
        branchName: String?,
        commitSHA: String?,
        changedFiles: [ChangedFileSummary],
        diffStat: DiffStat?
    ) {
        let targetPath = session.worktreePath ?? session.repoPath
        guard let targetPath else {
            return (session.branchName, nil, [], nil)
        }
        let gitService = GitService()

        let branch = try? await gitService.currentBranch(repoPath: targetPath)
        let commitSHA = try? await gitService.currentCommitSHA(repoPath: targetPath)
        let changedFiles = (try? await gitService.diffNameStatus(path: targetPath)) ?? []
        let diffStat = (try? await gitService.diffStat(path: targetPath))

        return (branch ?? session.branchName, commitSHA, changedFiles, diffStat)
    }

    func compareValue(for input: CompareInput) async -> (
        title: String,
        summary: String,
        sourceSessionID: UUID?,
        changedFiles: [ChangedFileSummary],
        diffStat: DiffStat?,
        testSummary: TestSummary?
    )? {
        switch input {
        case .checkpoint(let id):
            guard let checkpoint = checkpoints.first(where: { $0.id == id }) else { return nil }
            return (
                title: checkpoint.title,
                summary: checkpoint.summary,
                sourceSessionID: checkpoint.sessionID,
                changedFiles: checkpoint.changedFiles,
                diffStat: checkpoint.diffStat,
                testSummary: checkpoint.testSummary
            )
        case .session(let sessionID):
            guard let session = sessionService.sessions.first(where: { $0.id == sessionID }) else { return nil }
            let repoPath = session.worktreePath ?? session.repoPath
            guard let repoPath else {
                return (
                    title: session.title,
                    summary: session.statusText ?? session.subtitle,
                    sourceSessionID: session.id,
                    changedFiles: [],
                    diffStat: nil,
                    testSummary: nil
                )
            }

            let gitService = GitService()
            let files = (try? await gitService.diffNameStatus(path: repoPath)) ?? []
            let stat = try? await gitService.diffStat(path: repoPath)
            return (
                title: session.title,
                summary: session.statusText ?? session.subtitle,
                sourceSessionID: session.id,
                changedFiles: files,
                diffStat: stat,
                testSummary: nil
            )
        case .branches(let repoPath, let leftBranch, let rightBranch):
            let gitService = GitService()
            let files = (try? await gitService.diffNameStatus(path: repoPath, between: leftBranch, and: rightBranch)) ?? []
            let stat = try? await gitService.diffStat(path: repoPath, between: leftBranch, and: rightBranch)
            return (
                title: "\(leftBranch) ... \(rightBranch)",
                summary: URL(fileURLWithPath: repoPath).lastPathComponent,
                sourceSessionID: nil,
                changedFiles: files,
                diffStat: stat,
                testSummary: nil
            )
        }
    }

    func resolveSessionID(for envelope: AgentEventEnvelope) -> UUID? {
        if let sessionID = envelope.sessionID,
           sessionService.sessions.contains(where: { $0.id == sessionID }) {
            return sessionID
        }

        guard let sessionTitleHint = envelope.sessionTitleHint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionTitleHint.isEmpty else {
            return nil
        }

        let activeProjectID = sessionService.selectedSession?.projectID
        let candidates = sessionService.sessions.filter { session in
            guard let activeProjectID else { return false }
            guard session.projectID == activeProjectID else { return false }
            return session.title == sessionTitleHint
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0].id
    }

    func parseUUID(from value: JSONValue?) -> UUID? {
        guard let raw = value?.stringValue else { return nil }
        return UUID(uuidString: raw)
    }

    func parseStringArray(from value: JSONValue?) -> [String] {
        guard let values = value?.arrayValue else { return [] }
        return values.compactMap(\.stringValue)
    }

    func parseListText(_ text: String) -> [String] {
        text
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func sanitizeSelections() {
        if let selectedCheckpointID,
           !checkpoints.contains(where: { $0.id == selectedCheckpointID }) {
            self.selectedCheckpointID = checkpoints.sorted(by: { $0.createdAt > $1.createdAt }).first?.id
        }

        if let selectedReviewID,
           !reviews.contains(where: { $0.id == selectedReviewID }) {
            self.selectedReviewID = reviews.sorted(by: { $0.createdAt > $1.createdAt }).first?.id
        }

        if let selectedHandoffID,
           !handoffs.contains(where: { $0.id == selectedHandoffID }) {
            self.selectedHandoffID = handoffs.sorted(by: { $0.createdAt > $1.createdAt }).first?.id
        }
    }

    func parseChangedFiles(from value: JSONValue?) -> [ChangedFileSummary] {
        guard let array = value?.arrayValue else { return [] }
        return array.compactMap { item in
            guard let object = item.objectValue else { return nil }
            guard let path = object["path"]?.stringValue else { return nil }
            let additions = object["additions"]?.intValue
            let deletions = object["deletions"]?.intValue
            let status = object["status"]?.stringValue ?? "M"
            return ChangedFileSummary(path: path, additions: additions, deletions: deletions, status: status)
        }
    }

    func parseDiffStat(from value: JSONValue?) -> DiffStat? {
        guard let object = value?.objectValue else { return nil }
        guard let filesChanged = object["filesChanged"]?.intValue else { return nil }
        guard let additions = object["additions"]?.intValue else { return nil }
        guard let deletions = object["deletions"]?.intValue else { return nil }
        return DiffStat(filesChanged: filesChanged, additions: additions, deletions: deletions)
    }

    func parseTestSummary(from value: JSONValue?) -> TestSummary? {
        guard let object = value?.objectValue else { return nil }
        let statusRaw = object["status"]?.stringValue ?? TestStatus.unknown.rawValue
        let status = TestStatus(rawValue: statusRaw) ?? .unknown
        let text = object["summaryText"]?.stringValue ?? "Unknown"
        return TestSummary(status: status, summaryText: text)
    }

    func postApprovalNotificationIfNeeded(sessionID: UUID, title: String, summary: String) {
        guard !NSApp.isActive else { return }
        Task { @MainActor [sessionID, title, summary] in
            let notificationCenter = UNUserNotificationCenter.current()
            let granted = (try? await notificationCenter.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = summary
            content.sound = .default
            content.userInfo = ["sessionID": sessionID.uuidString]

            let request = UNNotificationRequest(
                identifier: "idx0.approval.\(sessionID.uuidString).\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
            _ = try? await addNotificationRequest(request)
        }
    }

    func addNotificationRequest(_ request: UNNotificationRequest) async throws {
        let notificationCenter = UNUserNotificationCenter.current()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            notificationCenter.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}
