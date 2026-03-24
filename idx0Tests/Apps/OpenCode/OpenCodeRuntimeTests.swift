import Foundation
import XCTest
@testable import idx0

@MainActor
final class OpenCodeRuntimeTests: XCTestCase {
    func testPrepareSessionStateCreatesXDGDirectories() throws {
        let root = temporaryOpenCodeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID()
        let paths = OpenCodeRuntimePaths(sessionID: sessionID, rootDirectoryOverride: root)
        let manager = OpenCodeStateSnapshotManager()

        let state = try manager.prepareSessionState(paths: paths)
        var isDirectory: ObjCBool = false

        XCTAssertTrue(FileManager.default.fileExists(atPath: state.xdgConfigHome.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.xdgDataHome.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.xdgCacheHome.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.xdgStateHome.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        XCTAssertEqual(state.environmentOverrides["XDG_CONFIG_HOME"], state.xdgConfigHome.path)
        XCTAssertEqual(state.environmentOverrides["XDG_DATA_HOME"], state.xdgDataHome.path)
        XCTAssertEqual(state.environmentOverrides["XDG_CACHE_HOME"], state.xdgCacheHome.path)
        XCTAssertEqual(state.environmentOverrides["XDG_STATE_HOME"], state.xdgStateHome.path)
    }

    func testRemoveSessionStateDeletesSessionDirectory() throws {
        let root = temporaryOpenCodeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID()
        let paths = OpenCodeRuntimePaths(sessionID: sessionID, rootDirectoryOverride: root)
        let manager = OpenCodeStateSnapshotManager()

        _ = try manager.prepareSessionState(paths: paths)
        let marker = paths.sessionDirectory.appendingPathComponent("marker.txt", isDirectory: false)
        try "marker".write(to: marker, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        manager.removeSessionState(paths: paths)

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.sessionDirectory.path))
    }

    func testOpenCodeRuntimeStateDisplayMessagesAreStable() {
        XCTAssertEqual(OpenCodeTileRuntimeState.idle.displayMessage, "Ready")
        XCTAssertEqual(OpenCodeTileRuntimeState.starting.displayMessage, "Starting OpenCode...")
        XCTAssertEqual(OpenCodeTileRuntimeState.live(urlString: "http://127.0.0.1:9999").displayMessage, "Live")
    }

    func testOpenCodeControllerUsesReadableDefaultZoom() {
        let controller = OpenCodeTileController(
            sessionID: UUID(),
            itemID: UUID(),
            launchDirectoryProvider: { FileManager.default.homeDirectoryForCurrentUser.path },
            snapshotManager: OpenCodeStateSnapshotManager()
        )

        XCTAssertEqual(controller.webView.pageZoom, 0.5, accuracy: 0.0001)
    }

    func testResolveExecutableReportsMissingToolDeterministically() async throws {
        let root = temporaryOpenCodeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let runner = StubOpenCodeProcessRunner { executable, arguments, _ in
            switch executable {
            case "/usr/bin/which":
                XCTAssertEqual(arguments, ["opencode"])
            case "/bin/zsh":
                XCTAssertTrue(
                    arguments == ["-lc", "whence -p opencode"] ||
                        arguments == ["-ilc", "whence -p opencode"]
                )
            default:
                XCTFail("Unexpected executable probe: \(executable)")
            }
            return ProcessResult(exitCode: 1, stdout: "", stderr: "not found")
        }

        let controller = OpenCodeTileController(
            sessionID: UUID(),
            itemID: UUID(),
            launchDirectoryProvider: { FileManager.default.homeDirectoryForCurrentUser.path },
            snapshotManager: OpenCodeStateSnapshotManager(),
            processRunner: runner,
            rootDirectoryOverride: root,
            executableSearchDirectoriesOverride: []
        )

        do {
            _ = try await controller.resolveOpenCodeExecutable()
            XCTFail("Expected missing executable error")
        } catch let error as OpenCodeRuntimeError {
            guard case .missingExecutable = error else {
                XCTFail("Unexpected OpenCode runtime error: \(error)")
                return
            }
        }
    }

    func testResolveExecutableFindsCommonInstallDirectoryWithoutPATHProbe() async throws {
        let root = temporaryOpenCodeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let executablePath = binDirectory.appendingPathComponent("opencode", isDirectory: false)
        _ = FileManager.default.createFile(
            atPath: executablePath.path,
            contents: Data("#!/bin/sh\necho opencode\n".utf8)
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executablePath.path)

        let runner = StubOpenCodeProcessRunner { executable, _, _ in
            XCTFail("Expected direct directory discovery before shell probes, got: \(executable)")
            return ProcessResult(exitCode: 1, stdout: "", stderr: "")
        }

        let controller = OpenCodeTileController(
            sessionID: UUID(),
            itemID: UUID(),
            launchDirectoryProvider: { FileManager.default.homeDirectoryForCurrentUser.path },
            snapshotManager: OpenCodeStateSnapshotManager(),
            processRunner: runner,
            rootDirectoryOverride: root,
            executableSearchDirectoriesOverride: [binDirectory.path]
        )

        let resolved = try await controller.resolveOpenCodeExecutable()
        XCTAssertEqual(resolved, executablePath.path)
    }

    func testStartupReportsProcessExitedBeforeReadyWhenProcessExitsEarly() async throws {
        let root = temporaryOpenCodeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let executablePath = binDirectory.appendingPathComponent("opencode", isDirectory: false)
        try writeExecutable(
            """
            #!/bin/sh
            sleep 1
            exit 1
            """,
            to: executablePath
        )

        let controller = OpenCodeTileController(
            sessionID: UUID(),
            itemID: UUID(),
            launchDirectoryProvider: { FileManager.default.homeDirectoryForCurrentUser.path },
            snapshotManager: OpenCodeStateSnapshotManager(),
            rootDirectoryOverride: root,
            executableSearchDirectoriesOverride: [binDirectory.path],
            baseEnvironmentOverride: ["PATH": binDirectory.path],
            readinessIntervalNanoseconds: 50_000_000,
            readinessTimeoutSeconds: 2
        )
        defer { controller.stop() }

        controller.ensureStarted()

        let failureMessage = await waitForFailureMessage(controller, timeout: 4)
        XCTAssertEqual(failureMessage, OpenCodeRuntimeError.processExitedBeforeReady.errorDescription)
    }

    func testStartupReportsMissingNodeWhenExecutableRequiresNodeAndNodeIsUnavailable() async throws {
        let root = temporaryOpenCodeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let executablePath = binDirectory.appendingPathComponent("opencode", isDirectory: false)
        try writeExecutable(
            """
            #!/usr/bin/env node
            process.exit(0)
            """,
            to: executablePath
        )

        let runner = StubOpenCodeProcessRunner { executable, arguments, _ in
            switch executable {
            case "/usr/bin/which":
                XCTAssertEqual(arguments, ["node"])
            case "/bin/zsh":
                XCTAssertTrue(
                    arguments == ["-lc", "whence -p node"] ||
                        arguments == ["-ilc", "whence -p node"]
                )
            default:
                XCTFail("Unexpected executable probe: \(executable)")
            }
            return ProcessResult(exitCode: 1, stdout: "", stderr: "not found")
        }

        let controller = OpenCodeTileController(
            sessionID: UUID(),
            itemID: UUID(),
            launchDirectoryProvider: { FileManager.default.homeDirectoryForCurrentUser.path },
            snapshotManager: OpenCodeStateSnapshotManager(),
            processRunner: runner,
            rootDirectoryOverride: root,
            executableSearchDirectoriesOverride: [binDirectory.path],
            baseEnvironmentOverride: ["PATH": ""],
            readinessIntervalNanoseconds: 50_000_000,
            readinessTimeoutSeconds: 1
        )
        defer { controller.stop() }

        controller.ensureStarted()

        let failureMessage = await waitForFailureMessage(controller, timeout: 2)
        XCTAssertEqual(failureMessage, OpenCodeRuntimeError.missingNodeExecutable.errorDescription)
    }

    private func temporaryOpenCodeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx0-opencode-runtime-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeExecutable(_ content: String, to path: URL) throws {
        try content.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    private func waitForFailureMessage(
        _ controller: OpenCodeTileController,
        timeout: TimeInterval
    ) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .failed(let message, _) = controller.state {
                return message
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }
}

private struct StubOpenCodeProcessRunner: ProcessRunnerProtocol {
    let block: @Sendable (String, [String], String?) async throws -> ProcessResult

    init(block: @escaping @Sendable (String, [String], String?) async throws -> ProcessResult) {
        self.block = block
    }

    func run(executable: String, arguments: [String], currentDirectory: String?) async throws -> ProcessResult {
        try await block(executable, arguments, currentDirectory)
    }
}
