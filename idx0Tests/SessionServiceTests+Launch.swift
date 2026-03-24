import XCTest
@testable import idx0

extension SessionServiceTests {
    func testControllerPreflightMarksMissingLaunchFolder() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Needs Path")).session
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx0-missing-\(UUID().uuidString)", isDirectory: true)
            .path
        service.updateTerminalMetadata(session.id, cwd: missingPath, suggestedTitle: nil)

        service.relaunchSession(session.id)
        let status = service.sessions.first(where: { $0.id == session.id })?.statusText
        XCTAssertTrue(status?.contains("Launch folder missing") ?? false)
    }

    func testLaunchManifestIsPersistedWhenControllerIsPrepared() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx0-service-launch-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = try Self.makeService(root: root)
        let session = try await service.createSession(from: SessionCreationRequest(title: "Manifest")).session
        let controller = service.controller(for: session.id)

        let manifestPath = root
            .appendingPathComponent("launchers", isDirectory: true)
            .appendingPathComponent(session.id.uuidString, isDirectory: true)
            .appendingPathComponent("launch-manifest.json", isDirectory: false)
            .path
        let helperPath = root
            .appendingPathComponent("launchers", isDirectory: true)
            .appendingPathComponent("idx0-session-launch-helper.sh", isDirectory: false)
            .path
        let wrapperPath = root
            .appendingPathComponent("launchers", isDirectory: true)
            .appendingPathComponent(session.id.uuidString, isDirectory: true)
            .appendingPathComponent("launch-wrapper.sh", isDirectory: false)
            .path
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: helperPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wrapperPath))
        XCTAssertEqual(controller?.shellPath, wrapperPath)
    }

    func testLaunchHelperWrapperExecutesManifestCommand() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx0-service-launch-wrapper-exec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let shellScriptPath = root.appendingPathComponent("fake-shell.sh", isDirectory: false).path
        let shellScript = "#!/bin/zsh\nexit 0\n"
        try shellScript.write(toFile: shellScriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellScriptPath)

        let service = try Self.makeService(root: root)
        let session = try await service.createSession(from: SessionCreationRequest(
            title: "Wrapper Exec",
            repoPath: nil,
            createWorktree: false,
            branchName: nil,
            existingWorktreePath: nil,
            shellPath: shellScriptPath
        )).session
        let controller = service.controller(for: session.id)

        guard let wrapperPath = controller?.shellPath else {
            XCTFail("Expected launch wrapper path")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: wrapperPath)
        process.currentDirectoryURL = root
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testLaunchWrapperFallsBackToShellWhenHelperExitsEarly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx0-service-launch-wrapper-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let shellScriptPath = root.appendingPathComponent("fake-shell.sh", isDirectory: false).path
        let shellScript = "#!/bin/zsh\nexit 0\n"
        try shellScript.write(toFile: shellScriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellScriptPath)

        let service = try Self.makeService(root: root)
        let session = try await service.createSession(from: SessionCreationRequest(
            title: "Wrapper Fallback",
            repoPath: nil,
            createWorktree: false,
            branchName: nil,
            existingWorktreePath: nil,
            shellPath: shellScriptPath
        )).session
        let controller = service.controller(for: session.id)

        guard let wrapperPath = controller?.shellPath else {
            XCTFail("Expected launch wrapper path")
            return
        }

        let helperPath = root
            .appendingPathComponent("launchers", isDirectory: true)
            .appendingPathComponent("idx0-session-launch-helper.sh", isDirectory: false)
            .path
        let failingHelper = "#!/bin/zsh\nexit 99\n"
        try failingHelper.write(toFile: helperPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: wrapperPath)
        process.currentDirectoryURL = root
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testLaunchHelperRestrictedProfileBuildsSandboxAndExecutes() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            throw XCTSkip("sandbox-exec is unavailable on this host")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx0-service-launch-restricted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let shellScriptPath = root.appendingPathComponent("fake-shell.sh", isDirectory: false).path
        let shellScript = "#!/bin/zsh\nexit 0\n"
        try shellScript.write(toFile: shellScriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellScriptPath)

        let service = try Self.makeService(root: root)
        let session = try await service.createSession(from: SessionCreationRequest(
            title: "Restricted Wrapper Exec",
            repoPath: root.path,
            createWorktree: false,
            branchName: nil,
            existingWorktreePath: nil,
            shellPath: shellScriptPath,
            sandboxProfile: .worktreeWrite,
            networkPolicy: .disabled
        )).session
        let controller = service.controller(for: session.id)

        guard let wrapperPath = controller?.shellPath else {
            XCTFail("Expected launch wrapper path")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: wrapperPath)
        process.currentDirectoryURL = root
        try process.run()
        process.waitUntilExit()

        let sandboxProfilePath = root
            .appendingPathComponent("launchers", isDirectory: true)
            .appendingPathComponent(session.id.uuidString, isDirectory: true)
            .appendingPathComponent("sandbox.sb", isDirectory: false)
            .path
        let launchResultPath = root
            .appendingPathComponent("launchers", isDirectory: true)
            .appendingPathComponent(session.id.uuidString, isDirectory: true)
            .appendingPathComponent("launch-result.json", isDirectory: false)
            .path

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandboxProfilePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: launchResultPath))

        let launchResultData = try Data(contentsOf: URL(fileURLWithPath: launchResultPath))
        let launchResult = try JSONDecoder().decode(LaunchHelperResult.self, from: launchResultData)
        XCTAssertEqual(launchResult.enforcementState, .enforced)
    }

    func testGhosttyCommandEscapingPreservesPathsWithSpaces() throws {
        let commandPath = "/Users/gal/Library/Application Support/idx0/temp/launchers/session/launch-wrapper.sh"
        let escaped = GhosttyAppHost.shellEscapedCommand(commandPath)
        XCTAssertEqual(escaped, "'\(commandPath)'")

        let output = try runBashScript("set -- \(escaped); printf '%s' \"$1\"")
        XCTAssertEqual(output, commandPath)
    }

    func testTerminalStartupTemplateExpansionReplacesWorkdirAndSessionID() throws {
        let fixture = try Fixture()
        let service = fixture.service
        let sessionID = UUID()
        let workdir = "/tmp/idx0 folder"

        service.saveSettings { settings in
            settings.terminalStartupCommandTemplate = "cd ${WORKDIR} && echo ${SESSION_ID}"
        }

        let expanded = service.expandedTerminalStartupCommand(
            for: sessionID,
            launchDirectory: workdir
        )

        XCTAssertEqual(
            expanded,
            "cd '\(workdir)' && echo \(sessionID.uuidString)"
        )
    }

    func testTerminalStartupTemplateExpansionReturnsNilForEmptyTemplate() throws {
        let fixture = try Fixture()
        let service = fixture.service

        service.saveSettings { settings in
            settings.terminalStartupCommandTemplate = "   "
        }

        XCTAssertNil(
            service.expandedTerminalStartupCommand(
                for: UUID(),
                launchDirectory: "/tmp"
            )
        )
    }

    func testRelaunchUsesPersistedManifestWhenSessionLaunchCwdIsStale() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx0-service-manifest-primary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = try Self.makeService(root: root)
        let session = try await service.createSession(from: SessionCreationRequest(title: "Manifest Primary")).session
        _ = service.controller(for: session.id)

        let stalePath = root
            .appendingPathComponent("stale-launch-dir-\(UUID().uuidString)", isDirectory: true)
            .path
        service.updateTerminalMetadata(session.id, cwd: stalePath, suggestedTitle: nil)

        try await Task.sleep(nanoseconds: 500_000_000)

        let sessionsFile = root.appendingPathComponent("sessions.json", isDirectory: false)
        var payload = try SessionStore(url: sessionsFile).load()
        guard let index = payload.sessions.firstIndex(where: { $0.id == session.id }) else {
            XCTFail("Expected persisted session")
            return
        }

        let validLaunchDirectory = root.appendingPathComponent("valid-launch", isDirectory: true)
        try FileManager.default.createDirectory(at: validLaunchDirectory, withIntermediateDirectories: true)

        let persisted = payload.sessions[index]
        payload.sessions[index].lastLaunchManifest = SessionLaunchManifest(
            sessionID: persisted.id,
            cwd: validLaunchDirectory.path,
            shellPath: persisted.shellPath,
            repoPath: persisted.repoPath,
            worktreePath: persisted.worktreePath,
            sandboxProfile: persisted.sandboxProfile,
            networkPolicy: persisted.networkPolicy,
            tempRoot: persisted.sandboxProfile == .worktreeAndTemp
                ? root.appendingPathComponent("launchers", isDirectory: true)
                    .appendingPathComponent(persisted.id.uuidString, isDirectory: true)
                    .appendingPathComponent("temp", isDirectory: true)
                    .path
                : nil,
            environment: [:],
            projectID: nil,
            ipcSocketPath: nil
        )
        payload.sessions[index].lastLaunchCwd = stalePath
        try SessionStore(url: sessionsFile).save(payload: payload)

        let restored = try Self.makeService(root: root)
        let controller = restored.controller(for: session.id)
        XCTAssertNil(controller?.launchBlockedReason)
    }

    func testBrowserStatePersistsAcrossRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx0-service-browser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = try Self.makeService(root: root)
        let session = try await service.createSession(from: SessionCreationRequest(title: "Browser")).session
        service.toggleBrowserSplit(for: session.id)
        service.setBrowserURL(for: session.id, urlString: "https://example.com")
        service.setBrowserSplitSide(for: session.id, side: .bottom)
        service.setBrowserSplitFraction(for: session.id, fraction: 0.33)

        try await Task.sleep(nanoseconds: 500_000_000)

        let restored = try Self.makeService(root: root)
        let restoredSession = restored.sessions.first(where: { $0.id == session.id })

        XCTAssertEqual(restoredSession?.browserState?.isVisible, true)
        XCTAssertEqual(URL(string: restoredSession?.browserState?.currentURL ?? "")?.host, "example.com")
        XCTAssertEqual(restoredSession?.browserState?.splitSide, .bottom)
        XCTAssertEqual(restoredSession?.browserState?.splitFraction, 0.33)
    }

    func testNiriBrowserURLPersistsAcrossRelaunchWithoutSplitState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx0-service-niri-browser-url-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = try Self.makeService(root: root)
        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Browser URL")).session
        service.saveSettings { $0.cleanupOnClose = false }
        service.ensureNiriLayoutState(for: session.id)

        guard let browserItemID = service.niriAddBrowserRight(in: session.id),
              let browserController = service.niriBrowserController(for: session.id, itemID: browserItemID)
        else {
            XCTFail("Expected browser tile controller")
            return
        }

        browserController.onURLChanged?("https://example.com/docs")

        let liveSession = service.sessions.first(where: { $0.id == session.id })
        XCTAssertNotNil(liveSession?.browserState)
        XCTAssertEqual(URL(string: liveSession?.browserState?.currentURL ?? "")?.host, "example.com")
        XCTAssertEqual(liveSession?.browserState?.isVisible, false)

        service.prepareForTermination()

        let restored = try Self.makeService(root: root)
        let restoredSession = restored.sessions.first(where: { $0.id == session.id })
        XCTAssertEqual(URL(string: restoredSession?.browserState?.currentURL ?? "")?.host, "example.com")

        let restoredBrowserItemID = restored.niriLayout(for: session.id)
            .workspaces
            .flatMap(\.columns)
            .flatMap(\.items)
            .first(where: { item in
                if case .browser = item.ref {
                    return true
                }
                return false
            })?.id

        XCTAssertNotNil(restoredBrowserItemID)
        if let restoredBrowserItemID {
            XCTAssertNotNil(restored.niriBrowserController(for: session.id, itemID: restoredBrowserItemID))
        }
    }

    func testRestrictedProfileWithoutWriteRootShowsDegradedState() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(
            title: "Restricted",
            repoPath: nil,
            createWorktree: false,
            branchName: nil,
            existingWorktreePath: nil,
            shellPath: nil,
            sandboxProfile: .worktreeWrite,
            networkPolicy: .disabled
        )).session

        _ = service.controller(for: session.id)
        let updated = service.sessions.first(where: { $0.id == session.id })

        XCTAssertEqual(updated?.sandboxEnforcementState, .degraded)
        XCTAssertTrue(updated?.statusText?.contains("Restrictions unavailable") ?? false)
    }

    func testCreateInactiveTabDoesNotLaunchController() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Inactive Tab")).session

        for (controllerID, controller) in service.runtimeControllers {
            controller.terminate()
            service.clearLaunchTracking(for: controllerID)
        }
        service.runtimeControllers.removeAll()
        service.ownerSessionIDByControllerID.removeAll()

        _ = service.createTab(in: session.id, activate: false)

        XCTAssertTrue(service.runtimeControllers.isEmpty)
    }

    func testFocusedNiriBrowserDoesNotLaunchTerminalController() async throws {
        let fixture = try Fixture()
        let service = fixture.service
        service.saveSettings { $0.niriCanvasEnabled = true }

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Browser")).session
        for (controllerID, controller) in service.runtimeControllers {
            controller.terminate()
            service.clearLaunchTracking(for: controllerID)
        }
        service.runtimeControllers.removeAll()
        service.ownerSessionIDByControllerID.removeAll()

        service.ensureNiriLayoutState(for: session.id)
        _ = service.niriAddBrowserRight(in: session.id)

        XCTAssertTrue(service.runtimeControllers.isEmpty)
    }

    func testFocusedNiriTerminalDoesNotLaunchWhenOverviewIsOpen() async throws {
        let fixture = try Fixture()
        let service = fixture.service
        service.saveSettings { $0.niriCanvasEnabled = true }

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Overview Launch Guard")).session
        service.ensureNiriLayoutState(for: session.id)

        for (controllerID, controller) in service.runtimeControllers {
            controller.terminate()
            service.clearLaunchTracking(for: controllerID)
        }
        service.runtimeControllers.removeAll()
        service.ownerSessionIDByControllerID.removeAll()
        service.visibleTerminalControllerIDsBySession.removeAll()

        service.toggleNiriOverview(sessionID: session.id)
        XCTAssertTrue(service.niriLayout(for: session.id).isOverviewOpen)

        let launched = service.launchFocusedNiriTerminalIfVisible(sessionID: session.id)

        XCTAssertTrue(launched.isEmpty)
        XCTAssertTrue(service.runtimeControllers.isEmpty)
        XCTAssertFalse(service.shouldLaunchVisibleTerminals(for: session.id))
        XCTAssertNil(service.visibleTerminalControllerIDsBySession[session.id])
    }

    func testHiddenRunningSessionReusesSameControllerOnReturn() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let first = try await service.createSession(from: SessionCreationRequest(title: "First")).session
        let second = try await service.createSession(from: SessionCreationRequest(title: "Second")).session

        service.focusSession(first.id)
        guard let firstController = service.ensureController(for: first.id) else {
            XCTFail("Expected first controller")
            return
        }
        _ = service.requestLaunchForActiveTerminals(in: first.id, reason: .explicitAction)

        service.focusSession(second.id)
        XCTAssertTrue(service.runtimeControllers[firstController.sessionID] === firstController)

        service.focusSession(first.id)
        let returnedController = service.ensureController(for: first.id)
        XCTAssertTrue(returnedController === firstController)
    }

    func testRelaunchAllSessionsStagesSelectedSessionFirst() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let first = try await service.createSession(from: SessionCreationRequest(title: "One")).session
        let second = try await service.createSession(from: SessionCreationRequest(title: "Two")).session
        let third = try await service.createSession(from: SessionCreationRequest(title: "Three")).session

        service.focusSession(second.id)
        for (controllerID, controller) in service.runtimeControllers {
            controller.terminate()
            service.clearLaunchTracking(for: controllerID)
        }
        service.runtimeControllers.removeAll()
        service.ownerSessionIDByControllerID.removeAll()
        service.visibleTerminalControllerIDsBySession.removeAll()

        service.relaunchAllSessions()

        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertNotNil(service.runtimeControllers[second.id])
        XCTAssertEqual(service.runtimeControllers.count, 1)

        try await Task.sleep(nanoseconds: 550_000_000)
        XCTAssertNotNil(service.runtimeControllers[first.id])
        XCTAssertNotNil(service.runtimeControllers[third.id])
        XCTAssertEqual(service.runtimeControllers.count, 3)
    }

    func testSwipeTrackerProjectsForwardWithPositiveVelocity() {
        var tracker = SwipeTracker(historyLimit: 0.150, deceleration: 0.997)
        tracker.push(delta: 12, at: 0.00)
        tracker.push(delta: 14, at: 0.04)
        tracker.push(delta: 13, at: 0.08)

        XCTAssertGreaterThan(tracker.velocity(), 0)
        XCTAssertGreaterThan(tracker.projectedEndPosition(), tracker.position)
    }

}
