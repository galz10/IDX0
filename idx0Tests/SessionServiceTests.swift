import Foundation
import SwiftUI
import XCTest
@testable import idx0

@MainActor
final class SessionServiceTests: XCTestCase {
    func testCloseSelectedSessionSelectsPreviousSessionWhenPossible() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let first = try await service.createSession(from: SessionCreationRequest(title: "One", repoPath: nil, createWorktree: false, branchName: nil, existingWorktreePath: nil, shellPath: nil)).session
        let second = try await service.createSession(from: SessionCreationRequest(title: "Two", repoPath: nil, createWorktree: false, branchName: nil, existingWorktreePath: nil, shellPath: nil)).session
        let third = try await service.createSession(from: SessionCreationRequest(title: "Three", repoPath: nil, createWorktree: false, branchName: nil, existingWorktreePath: nil, shellPath: nil)).session

        service.selectSession(second.id)
        service.closeSession(second.id)

        XCTAssertEqual(service.selectedSessionID, first.id)
        XCTAssertTrue(service.sessions.contains(where: { $0.id == first.id }))
        XCTAssertFalse(service.sessions.contains(where: { $0.id == second.id }))
        XCTAssertTrue(service.sessions.contains(where: { $0.id == third.id }))
    }

    func testSuggestedTitleIgnoredWhenCustomTitleExists() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let custom = try await service.createSession(from: SessionCreationRequest(title: "Custom", repoPath: nil, createWorktree: false, branchName: nil, existingWorktreePath: nil, shellPath: nil)).session
        service.updateTerminalMetadata(custom.id, cwd: nil, suggestedTitle: "From Terminal")

        XCTAssertEqual(service.sessions.first(where: { $0.id == custom.id })?.title, "Custom")

        let auto = try await service.createSession(from: SessionCreationRequest(title: nil, repoPath: nil, createWorktree: false, branchName: nil, existingWorktreePath: nil, shellPath: nil)).session
        service.updateTerminalMetadata(auto.id, cwd: nil, suggestedTitle: "Auto Updated")

        XCTAssertEqual(service.sessions.first(where: { $0.id == auto.id })?.title, "Auto Updated")
    }

    func testGroupsSessionsByProject() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let first = try await service.createSession(from: SessionCreationRequest(
            title: "A1",
            repoPath: "/tmp/repo-a",
            createWorktree: false
        )).session
        let second = try await service.createSession(from: SessionCreationRequest(
            title: "A2",
            repoPath: "/tmp/repo-a",
            createWorktree: false
        )).session
        _ = try await service.createSession(from: SessionCreationRequest(
            title: "B1",
            repoPath: "/tmp/repo-b",
            createWorktree: false
        )).session

        XCTAssertEqual(service.projectSections.count, 2)

        let sectionForA = service.projectSections.first(where: { $0.group.title == "repo-a" })
        XCTAssertNotNil(sectionForA)
        XCTAssertEqual(sectionForA?.sessions.map(\.id), [second.id, first.id])
    }

    func testPinnedSessionsStayStableAboveRecentSorting() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let first = try await service.createSession(from: SessionCreationRequest(
            title: "A1",
            repoPath: "/tmp/repo-a",
            createWorktree: false
        )).session
        let second = try await service.createSession(from: SessionCreationRequest(
            title: "A2",
            repoPath: "/tmp/repo-a",
            createWorktree: false
        )).session

        service.setPinned(second.id, pinned: true)
        service.selectSession(first.id)

        let pinnedFirstOrder = service.projectSections
            .first(where: { $0.group.title == "repo-a" })?
            .sessions
            .map(\.id)
        XCTAssertEqual(pinnedFirstOrder?.first, second.id)

        service.setPinned(second.id, pinned: false)
        let unpinnedOrder = service.projectSections
            .first(where: { $0.group.title == "repo-a" })?
            .sessions
            .map(\.id)
        XCTAssertEqual(unpinnedOrder?.first, first.id)
    }

    func testFocusSessionDoesNotUpdateRecentOrdering() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let first = try await service.createSession(from: SessionCreationRequest(
            title: "A1",
            repoPath: "/tmp/repo-a",
            createWorktree: false
        )).session
        let second = try await service.createSession(from: SessionCreationRequest(
            title: "A2",
            repoPath: "/tmp/repo-a",
            createWorktree: false
        )).session

        let beforeOrder = service.projectSections
            .first(where: { $0.group.title == "repo-a" })?
            .sessions
            .map(\.id)
        XCTAssertEqual(beforeOrder, [second.id, first.id])

        service.focusSession(first.id)

        let afterOrder = service.projectSections
            .first(where: { $0.group.title == "repo-a" })?
            .sessions
            .map(\.id)
        XCTAssertEqual(afterOrder, [second.id, first.id])
        XCTAssertEqual(service.selectedSessionID, first.id)
    }

    func testAttentionQueueUrgencyAndVisitResolution() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let first = try await service.createSession(from: SessionCreationRequest(title: "One")).session
        let second = try await service.createSession(from: SessionCreationRequest(title: "Two")).session

        service.injectAttention(sessionID: first.id, reason: .notification, message: "FYI")
        service.injectAttention(sessionID: second.id, reason: .error, message: "Boom")
        service.injectAttention(sessionID: first.id, reason: .needsInput, message: "Approve")

        let unresolved = service.unresolvedAttentionItems
        XCTAssertEqual(unresolved.count, 2)
        XCTAssertEqual(unresolved.first?.sessionID, second.id)
        XCTAssertEqual(unresolved.first?.reason, .error)
        XCTAssertEqual(unresolved.last?.sessionID, first.id)
        XCTAssertEqual(unresolved.last?.reason, .needsInput)

        service.selectSession(first.id)
        XCTAssertEqual(service.unresolvedAttentionItems.count, 1)
        XCTAssertEqual(service.unresolvedAttentionItems.first?.sessionID, second.id)
        XCTAssertEqual(service.sessions.first(where: { $0.id == first.id })?.latestAttentionReason, nil)
    }

    func testRestoreMetadataBehaviorMarksSessionsAsNotRunning() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx0-service-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = try Self.makeService(root: root)
        _ = try await service.createSession(from: SessionCreationRequest(title: "Saved")).session

        try await Task.sleep(nanoseconds: 500_000_000)

        // Override to metadata-only so this test exercises the metadata-only path
        let service2 = try Self.makeService(root: root)
        service2.saveSettings { $0.restoreBehavior = .restoreMetadataOnly }
        try await Task.sleep(nanoseconds: 200_000_000)

        let restored = try Self.makeService(root: root)
        XCTAssertEqual(restored.settings.restoreBehavior, .restoreMetadataOnly)
        XCTAssertTrue(restored.sessions.first?.statusText?.contains("Restored metadata only") ?? false)
    }

    func testRelaunchSelectedRestoreBehaviorMarksOnlyUnselectedSessions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx0-service-restore-selected-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = try Self.makeService(root: root)
        let first = try await service.createSession(from: SessionCreationRequest(title: "One")).session
        _ = try await service.createSession(from: SessionCreationRequest(title: "Two")).session
        service.selectSession(first.id)
        service.saveSettings { $0.restoreBehavior = .relaunchSelectedSession }

        try await Task.sleep(nanoseconds: 500_000_000)

        let restored = try Self.makeService(root: root)
        let selected = restored.sessions.first(where: { $0.id == first.id })
        let unselected = restored.sessions.first(where: { $0.id != first.id })

        XCTAssertFalse(selected?.statusText?.contains("Restored metadata only") ?? false)
        XCTAssertTrue(unselected?.statusText?.contains("Restored metadata only") ?? false)
    }

    func testRelaunchAllRestoreBehaviorDoesNotUseMetadataOnlyStatus() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx0-service-restore-all-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = try Self.makeService(root: root)
        _ = try await service.createSession(from: SessionCreationRequest(title: "One")).session
        _ = try await service.createSession(from: SessionCreationRequest(title: "Two")).session
        service.saveSettings { $0.restoreBehavior = .relaunchAllSessions }

        try await Task.sleep(nanoseconds: 500_000_000)

        let restored = try Self.makeService(root: root)
        let hasMetadataOnly = restored.sessions.contains { session in
            session.statusText?.contains("Restored metadata only") == true
        }
        XCTAssertFalse(hasMetadataOnly)
    }

    func testPersistenceQueueKeepsLatestSessionSnapshotUnderBurstUpdates() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx0-persist-burst-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = try Self.makeService(root: root)
        let session = try await service.createSession(from: SessionCreationRequest(title: "Burst 0")).session

        for index in 1...40 {
            service.renameSession(session.id, title: "Burst \(index)")
        }
        service.persistNow()

        let payload = try SessionStore(url: root.appendingPathComponent("sessions.json", isDirectory: false)).load()
        let persisted = payload.sessions.first(where: { $0.id == session.id })
        XCTAssertEqual(persisted?.title, "Burst 40")
    }

    func testTileStateRestoresAcrossRelaunchWhenCleanupOnCloseDisabled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx0-tile-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = try Self.makeService(root: root)
        service.saveSettings { $0.cleanupOnClose = false }
        let session = try await service.createSession(from: SessionCreationRequest(title: "Tile Restore")).session
        service.ensureNiriLayoutState(for: session.id)
        _ = service.niriAddTerminalRight(in: session.id)
        _ = service.niriAddBrowserRight(in: session.id)

        let tabCountBefore = service.tabs(for: session.id).count
        let browserTileCountBefore = service.niriLayout(for: session.id)
            .workspaces
            .flatMap(\.columns)
            .flatMap(\.items)
            .filter { item in
                if case .browser = item.ref {
                    return true
                }
                return false
            }
            .count

        XCTAssertGreaterThan(tabCountBefore, 1)
        XCTAssertEqual(browserTileCountBefore, 1)

        service.prepareForTermination()

        let restored = try Self.makeService(root: root)
        let restoredTabCount = restored.tabs(for: session.id).count
        let restoredBrowserTileCount = restored.niriLayout(for: session.id)
            .workspaces
            .flatMap(\.columns)
            .flatMap(\.items)
            .filter { item in
                if case .browser = item.ref {
                    return true
                }
                return false
            }
            .count

        XCTAssertEqual(restoredTabCount, tabCountBefore)
        XCTAssertEqual(restoredBrowserTileCount, browserTileCountBefore)
    }

    func testTileStateIsClearedAcrossRelaunchWhenCleanupOnCloseEnabled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx0-tile-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = try Self.makeService(root: root)
        let session = try await service.createSession(from: SessionCreationRequest(title: "Tile Cleanup")).session
        service.ensureNiriLayoutState(for: session.id)
        _ = service.niriAddTerminalRight(in: session.id)
        _ = service.niriAddBrowserRight(in: session.id)
        service.saveSettings { $0.cleanupOnClose = true }

        service.prepareForTermination()

        let restored = try Self.makeService(root: root)
        restored.ensureNiriLayoutState(for: session.id)
        let restoredBrowserTileCount = restored.niriLayout(for: session.id)
            .workspaces
            .flatMap(\.columns)
            .flatMap(\.items)
            .filter { item in
                if case .browser = item.ref {
                    return true
                }
                return false
            }
            .count

        XCTAssertTrue(restored.settings.cleanupOnClose)
        XCTAssertEqual(restored.tabs(for: session.id).count, 1)
        XCTAssertEqual(restoredBrowserTileCount, 0)
    }

    func testSchema1SessionsMigrateIntoProjectGroups() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx0-schema1-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = FileSystemPaths(
            appSupportDirectory: root,
            sessionsFile: root.appendingPathComponent("sessions.json"),
            projectsFile: root.appendingPathComponent("projects.json"),
            inboxFile: root.appendingPathComponent("inbox.json"),
            settingsFile: root.appendingPathComponent("settings.json"),
            runDirectory: root.appendingPathComponent("run", isDirectory: true),
            tempDirectory: root.appendingPathComponent("temp", isDirectory: true),
            worktreesDirectory: root.appendingPathComponent("worktrees", isDirectory: true)
        )
        try paths.ensureDirectories()

        let now = Date()
        let sessionA = Session(
            id: UUID(),
            title: "RepoA",
            hasCustomTitle: true,
            createdAt: now,
            lastActiveAt: now,
            repoPath: "/tmp/repo-a",
            branchName: "main",
            worktreePath: nil,
            isWorktreeBacked: false,
            shellPath: "/bin/zsh",
            attentionState: .normal,
            statusText: nil,
            lastKnownCwd: "/tmp/repo-a"
        )
        let sessionB = Session(
            id: UUID(),
            title: "RepoB",
            hasCustomTitle: true,
            createdAt: now,
            lastActiveAt: now,
            repoPath: "/tmp/repo-b",
            branchName: "main",
            worktreePath: nil,
            isWorktreeBacked: false,
            shellPath: "/bin/zsh",
            attentionState: .normal,
            statusText: nil,
            lastKnownCwd: "/tmp/repo-b"
        )

        try SessionStore(url: paths.sessionsFile).save(
            payload: SessionsFilePayload(
                schemaVersion: 1,
                selectedSessionID: sessionA.id,
                sessions: [sessionA, sessionB]
            )
        )

        let service = try Self.makeService(root: root)
        XCTAssertEqual(service.projectSections.count, 2)
        XCTAssertNotNil(service.projectSections.first(where: { $0.group.title == "repo-a" }))
        XCTAssertNotNil(service.projectSections.first(where: { $0.group.title == "repo-b" }))
    }

    func testSchema1SessionsWithSameRepoMigrateIntoSingleGroup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx0-schema1-single-group-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = FileSystemPaths(
            appSupportDirectory: root,
            sessionsFile: root.appendingPathComponent("sessions.json"),
            projectsFile: root.appendingPathComponent("projects.json"),
            inboxFile: root.appendingPathComponent("inbox.json"),
            settingsFile: root.appendingPathComponent("settings.json"),
            runDirectory: root.appendingPathComponent("run", isDirectory: true),
            tempDirectory: root.appendingPathComponent("temp", isDirectory: true),
            worktreesDirectory: root.appendingPathComponent("worktrees", isDirectory: true)
        )
        try paths.ensureDirectories()

        let now = Date()
        let older = now.addingTimeInterval(-60)
        let sessionA = Session(
            id: UUID(),
            title: "RepoA-main",
            hasCustomTitle: true,
            createdAt: older,
            lastActiveAt: older,
            repoPath: "/tmp/repo-a",
            branchName: "main",
            worktreePath: nil,
            isWorktreeBacked: false,
            shellPath: "/bin/zsh",
            attentionState: .normal,
            statusText: nil,
            lastKnownCwd: "/tmp/repo-a"
        )
        let sessionB = Session(
            id: UUID(),
            title: "RepoA-feature",
            hasCustomTitle: true,
            createdAt: now,
            lastActiveAt: now,
            repoPath: "/tmp/repo-a",
            branchName: "feature",
            worktreePath: nil,
            isWorktreeBacked: false,
            shellPath: "/bin/zsh",
            attentionState: .normal,
            statusText: nil,
            lastKnownCwd: "/tmp/repo-a"
        )

        try SessionStore(url: paths.sessionsFile).save(
            payload: SessionsFilePayload(
                schemaVersion: 1,
                selectedSessionID: sessionB.id,
                sessions: [sessionA, sessionB]
            )
        )

        let service = try Self.makeService(root: root)
        let repoASections = service.projectSections.filter { $0.group.title == "repo-a" }
        XCTAssertEqual(repoASections.count, 1)
        XCTAssertEqual(repoASections.first?.sessions.count, 2)
        XCTAssertEqual(repoASections.first?.sessions.first?.id, sessionB.id)
    }

    func testUnsupportedSchemaDoesNotOverwriteExistingSessionsFileOnPersist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx0-schema-future-protect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = FileSystemPaths(
            appSupportDirectory: root,
            sessionsFile: root.appendingPathComponent("sessions.json"),
            projectsFile: root.appendingPathComponent("projects.json"),
            inboxFile: root.appendingPathComponent("inbox.json"),
            settingsFile: root.appendingPathComponent("settings.json"),
            runDirectory: root.appendingPathComponent("run", isDirectory: true),
            tempDirectory: root.appendingPathComponent("temp", isDirectory: true),
            worktreesDirectory: root.appendingPathComponent("worktrees", isDirectory: true)
        )
        try paths.ensureDirectories()

        let now = Date()
        let persistedSession = Session(
            id: UUID(),
            title: "Future Session",
            hasCustomTitle: true,
            createdAt: now,
            lastActiveAt: now,
            repoPath: "/tmp/repo-future",
            branchName: "main",
            worktreePath: nil,
            isWorktreeBacked: false,
            shellPath: "/bin/zsh",
            attentionState: .normal,
            statusText: nil,
            lastKnownCwd: "/tmp/repo-future"
        )
        let futurePayload = SessionsFilePayload(
            schemaVersion: PersistenceSchema.currentVersion + 1,
            selectedSessionID: persistedSession.id,
            sessions: [persistedSession]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(futurePayload).write(to: paths.sessionsFile)

        let worktree = WorktreeService(gitService: GitService(), paths: paths)
        let service = SessionService(
            sessionStore: SessionStore(url: paths.sessionsFile),
            projectStore: ProjectStore(url: paths.projectsFile),
            inboxStore: InboxStore(url: paths.inboxFile),
            settingsStore: SettingsStore(url: paths.settingsFile),
            worktreeService: worktree,
            launcherDirectory: root.appendingPathComponent("launchers", isDirectory: true),
            host: .shared
        )

        service.prepareForTermination()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(SessionsFilePayload.self, from: Data(contentsOf: paths.sessionsFile))
        XCTAssertEqual(persisted.schemaVersion, PersistenceSchema.currentVersion + 1)
        XCTAssertEqual(persisted.sessions.map(\.title), ["Future Session"])
    }

    func testSwipeTrackerHistoryWindowDropsOldEvents() {
        var tracker = SwipeTracker(historyLimit: 0.100, deceleration: 0.997)
        tracker.push(delta: 40, at: 0.00)
        tracker.push(delta: 10, at: 0.20)
        tracker.push(delta: 10, at: 0.24)

        XCTAssertGreaterThan(tracker.velocity(), 300)
    }

    func makeStubNiriAppDescriptor(appID: String, tracker: StubNiriAppTracker) -> NiriAppDescriptor {
        NiriAppDescriptor(
            id: appID,
            displayName: "Stub App",
            icon: "puzzlepiece.extension",
            menuSubtitle: "Test app",
            isVisibleInMenus: true,
            supportsWebZoomPersistence: true,
            startTile: { _, _ in nil },
            retryTile: { _, sessionID, itemID in
                tracker.retryCalls.append((sessionID: sessionID, itemID: itemID))
                tracker.controller(for: itemID)?.retry()
            },
            stopTile: { _, itemID in
                tracker.stopCalls.append(itemID)
                tracker.controller(for: itemID)?.stop()
                tracker.removeController(for: itemID)
            },
            ensureController: { _, sessionID, itemID in
                tracker.ensureCalls.append((sessionID: sessionID, itemID: itemID))
                return tracker.ensureController(sessionID: sessionID, itemID: itemID)
            },
            makeTileView: { _, _, _ in AnyView(EmptyView()) },
            cleanupSessionArtifacts: { _, sessionID in
                tracker.recordCleanup(for: sessionID)
            }
        )
    }

    func addStubNiriAppTile(appID: String, sessionID: UUID, service: SessionService) -> UUID {
        service.ensureNiriLayoutState(for: sessionID)
        var layout = service.niriLayout(for: sessionID)
        let workspaceIndex = niriActiveWorkspaceIndex(layout) ?? 0

        let itemID = UUID()
        let item = NiriLayoutItem(id: itemID, ref: .app(appID: appID))
        let column = NiriColumn(id: UUID(), items: [item], focusedItemID: itemID, displayMode: .normal)

        layout.workspaces[workspaceIndex].columns.append(column)
        layout.camera.activeWorkspaceID = layout.workspaces[workspaceIndex].id
        layout.camera.activeColumnID = column.id
        layout.camera.focusedItemID = itemID
        service.setNiriLayoutForTesting(sessionID: sessionID, layout: layout)

        return itemID
    }

    func assertHasSingleTrailingEmptyWorkspace(
        _ layout: NiriCanvasLayout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(layout.workspaces.isEmpty, file: file, line: line)
        let trailingEmptyCount = layout.workspaces.suffix(1).filter { $0.columns.isEmpty }.count
        XCTAssertEqual(trailingEmptyCount, 1, file: file, line: line)
        XCTAssertTrue(layout.workspaces.dropLast().allSatisfy { !$0.columns.isEmpty }, file: file, line: line)
    }

    func niriActiveWorkspaceIndex(_ layout: NiriCanvasLayout) -> Int? {
        if let activeWorkspaceID = layout.camera.activeWorkspaceID,
           let index = layout.workspaces.firstIndex(where: { $0.id == activeWorkspaceID }) {
            return index
        }
        return layout.workspaces.firstIndex(where: { !$0.columns.isEmpty }) ?? (layout.workspaces.isEmpty ? nil : 0)
    }

    func niriActiveColumnIndex(_ layout: NiriCanvasLayout, workspaceIndex: Int) -> Int? {
        guard workspaceIndex >= 0, workspaceIndex < layout.workspaces.count else { return nil }
        let workspace = layout.workspaces[workspaceIndex]
        if let activeColumnID = layout.camera.activeColumnID,
           let index = workspace.columns.firstIndex(where: { $0.id == activeColumnID }) {
            return index
        }
        return workspace.columns.isEmpty ? nil : 0
    }

    @MainActor
    final class StubNiriAppTracker {
        var ensureCalls: [(sessionID: UUID, itemID: UUID)] = []
        var retryCalls: [(sessionID: UUID, itemID: UUID)] = []
        var stopCalls: [UUID] = []

        private var cleanupCallsBySession: [UUID: Int] = [:]
        private var controllersByItemID: [UUID: StubNiriAppController] = [:]

        func ensureController(sessionID: UUID, itemID: UUID) -> StubNiriAppController {
            if let existing = controllersByItemID[itemID] {
                return existing
            }
            let created = StubNiriAppController(sessionID: sessionID)
            controllersByItemID[itemID] = created
            return created
        }

        func controller(for itemID: UUID) -> StubNiriAppController? {
            controllersByItemID[itemID]
        }

        func removeController(for itemID: UUID) {
            controllersByItemID.removeValue(forKey: itemID)
        }

        func recordCleanup(for sessionID: UUID) {
            cleanupCallsBySession[sessionID, default: 0] += 1
        }

        func cleanupCallCount(for sessionID: UUID) -> Int {
            cleanupCallsBySession[sessionID, default: 0]
        }
    }

    @MainActor
    final class StubNiriAppController: NiriAppTileRuntimeControlling {
        let sessionID: UUID
        private(set) var retryCount = 0
        private(set) var stopCount = 0
        private(set) var zoomAdjustments: [CGFloat] = []

        init(sessionID: UUID) {
            self.sessionID = sessionID
        }

        func retry() {
            retryCount += 1
        }

        func stop() {
            stopCount += 1
        }

        @discardableResult
        func adjustZoom(by delta: CGFloat) -> Bool {
            zoomAdjustments.append(delta)
            return true
        }
    }

    static func makeService(
        root: URL,
        niriAppRegistry: NiriAppRegistry = NiriAppRegistry()
    ) throws -> SessionService {
        let paths = FileSystemPaths(
            appSupportDirectory: root,
            sessionsFile: root.appendingPathComponent("sessions.json"),
            projectsFile: root.appendingPathComponent("projects.json"),
            inboxFile: root.appendingPathComponent("inbox.json"),
            settingsFile: root.appendingPathComponent("settings.json"),
            runDirectory: root.appendingPathComponent("run", isDirectory: true),
            tempDirectory: root.appendingPathComponent("temp", isDirectory: true),
            worktreesDirectory: root.appendingPathComponent("worktrees", isDirectory: true)
        )
        try paths.ensureDirectories()

        let gitService = GitService()
        let worktree = WorktreeService(gitService: gitService, paths: paths)
        return SessionService(
            sessionStore: SessionStore(url: paths.sessionsFile),
            projectStore: ProjectStore(url: paths.projectsFile),
            inboxStore: InboxStore(url: paths.inboxFile),
            settingsStore: SettingsStore(url: paths.settingsFile),
            worktreeService: worktree,
            launcherDirectory: root.appendingPathComponent("launchers", isDirectory: true),
            niriAppRegistry: niriAppRegistry,
            host: .shared
        )
    }

    @MainActor
    struct Fixture {
        let service: SessionService

        init(niriAppRegistry: NiriAppRegistry = NiriAppRegistry()) throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("idx0-service-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            service = try SessionServiceTests.makeService(root: root, niriAppRegistry: niriAppRegistry)
        }
    }

    func runBashScript(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", "-c", script]

        let stdout = Pipe()
        process.standardOutput = stdout

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}

final class ShellIntegrationHealthServiceTests: XCTestCase {
    private let service = ShellIntegrationHealthService()

    func testExplicitShellTakesPrecedenceWhenExecutable() throws {
        let explicit = try makeExecutableFile()
        let preferred = try makeExecutableFile()
        defer {
            try? FileManager.default.removeItem(atPath: explicit)
            try? FileManager.default.removeItem(atPath: preferred)
        }

        let resolved = try service.resolvedShell(explicitShell: explicit, preferredShell: preferred)
        XCTAssertEqual(resolved, explicit)
    }

    func testInvalidExplicitShellThrows() throws {
        let preferred = try makeExecutableFile()
        defer { try? FileManager.default.removeItem(atPath: preferred) }

        XCTAssertThrowsError(
            try service.resolvedShell(explicitShell: "/tmp/idx0-shell-does-not-exist", preferredShell: preferred)
        ) { error in
            guard case ShellIntegrationHealthError.invalidShellPath = error else {
                XCTFail("Expected invalidShellPath error, got: \(error)")
                return
            }
        }
    }

    func testPreferredShellUsedWhenExplicitMissing() throws {
        let preferred = try makeExecutableFile()
        defer { try? FileManager.default.removeItem(atPath: preferred) }

        let resolved = try service.resolvedShell(explicitShell: nil, preferredShell: preferred)
        XCTAssertEqual(resolved, preferred)
    }

    func makeExecutableFile() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx0-shell-\(UUID().uuidString)")
            .path

        let script = "#!/bin/sh\nexit 0\n"
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }
}

final class VibeCLIDiscoveryServiceTests: XCTestCase {
    func testGeminiCliToolDetectsGeminiBinaryAlias() throws {
        let binDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx0-gemini-alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: binDirectory) }

        let geminiPath = binDirectory.appendingPathComponent("gemini", isDirectory: false).path
        try "#!/bin/sh\nexit 0\n".write(toFile: geminiPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: geminiPath)

        let service = VibeCLIDiscoveryService(
            environment: ["PATH": binDirectory.path],
            shellLookup: { _ in nil }
        )

        let tool = service.tool(withID: "gemini-cli")
        XCTAssertEqual(tool?.isInstalled, true)
        XCTAssertEqual(tool?.resolvedPath, geminiPath)
    }

    func testCodexToolDetectsNvmVersionBinWhenPathMissingCodex() throws {
        let temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx0-home-\(UUID().uuidString)", isDirectory: true)
        let nvmBinDirectory = temporaryHome
            .appendingPathComponent(".nvm/versions/node/v22.22.0/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: nvmBinDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryHome) }

        let codexPath = nvmBinDirectory.appendingPathComponent("codex", isDirectory: false).path
        try "#!/bin/sh\nexit 0\n".write(toFile: codexPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexPath)

        let service = VibeCLIDiscoveryService(
            environment: [
                "PATH": "/usr/bin:/bin",
                "HOME": temporaryHome.path,
                "ZDOTDIR": temporaryHome.path
            ],
            shellLookup: { _ in nil },
            homeDirectory: temporaryHome.path
        )

        let tool = service.tool(withID: "codex")
        XCTAssertEqual(tool?.isInstalled, true)
        XCTAssertEqual(
            tool?.resolvedPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            URL(fileURLWithPath: codexPath).resolvingSymlinksInPath().path
        )
    }

}
