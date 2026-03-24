import Foundation
import XCTest
@testable import idx0

@MainActor
final class ExcalidrawRuntimeTests: XCTestCase {
    func testRuntimePathsEnsureBaseDirectoriesCreatesSessionDirectory() throws {
        let root = temporaryExcalidrawRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID()
        let paths = ExcalidrawRuntimePaths(sessionID: sessionID, rootDirectoryOverride: root)

        try paths.ensureBaseDirectories()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.sessionDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testRemoveSessionArtifactsDeletesSessionDirectory() throws {
        let root = temporaryExcalidrawRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID()
        let paths = ExcalidrawRuntimePaths(sessionID: sessionID, rootDirectoryOverride: root)
        try paths.ensureBaseDirectories()

        let marker = paths.sessionDirectory.appendingPathComponent("marker.txt", isDirectory: false)
        try "marker".write(to: marker, atomically: true, encoding: .utf8)

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        paths.removeSessionArtifacts()
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.sessionDirectory.path))
    }

    func testExcalidrawTileRuntimeStateDisplayMessagesAreStable() {
        XCTAssertEqual(ExcalidrawTileRuntimeState.idle.displayMessage, "Ready")
        XCTAssertEqual(ExcalidrawTileRuntimeState.preparingSource.displayMessage, "Preparing Excalidraw source...")
        XCTAssertEqual(ExcalidrawTileRuntimeState.building.displayMessage, "Building Excalidraw...")
        XCTAssertEqual(ExcalidrawTileRuntimeState.starting.displayMessage, "Starting Excalidraw...")
        XCTAssertEqual(ExcalidrawTileRuntimeState.live(urlString: "http://127.0.0.1:9999").displayMessage, "Live")
    }

    func testBuildCoordinatorFailsWhenYarnMissing() async throws {
        let root = temporaryExcalidrawRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = ExcalidrawRuntimePaths(sessionID: UUID(), rootDirectoryOverride: root)
        let runner = StubExcalidrawProcessRunner { executable, arguments, _ in
            guard executable == "/usr/bin/which", let tool = arguments.first else {
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }

            if tool == "yarn" {
                return ProcessResult(exitCode: 1, stdout: "", stderr: "not found")
            }
            return ProcessResult(exitCode: 0, stdout: "/usr/bin/\(tool)", stderr: "")
        }
        let coordinator = ExcalidrawBuildCoordinator(processRunner: runner, fileManager: .default)

        do {
            _ = try await coordinator.ensureBuilt(manifest: .default, paths: paths)
            XCTFail("Expected missing-tool error")
        } catch let error as ExcalidrawRuntimeError {
            guard case .missingTool(let name) = error else {
                XCTFail("Unexpected Excalidraw runtime error: \(error)")
                return
            }
            XCTAssertEqual(name, "yarn")
        }
    }

    func testBuildCoordinatorReusesExistingArtifactsWithoutInvokingRunner() async throws {
        let root = temporaryExcalidrawRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = ExcalidrawRuntimePaths(sessionID: UUID(), rootDirectoryOverride: root)
        try paths.ensureBaseDirectories()
        try FileManager.default.createDirectory(at: paths.sourceDirectory, withIntermediateDirectories: true)

        let manifest = ExcalidrawBuildManifest(
            repositoryURL: "https://example.com/unused.git",
            pinnedCommit: "abc123",
            installCommand: "unused",
            buildCommand: "unused",
            entrypoint: "excalidraw-app/build/index.html",
            requiredArtifacts: ["excalidraw-app/build/index.html"]
        )

        for artifact in manifest.requiredArtifacts {
            let artifactURL = paths.sourceDirectory.appendingPathComponent(artifact, isDirectory: false)
            try FileManager.default.createDirectory(at: artifactURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: artifactURL)
        }

        struct BuildRecordMirror: Codable {
            let pinnedCommit: String
            let entrypoint: String
            let builtAt: Date
        }

        let record = BuildRecordMirror(
            pinnedCommit: manifest.pinnedCommit,
            entrypoint: manifest.entrypoint,
            builtAt: Date()
        )
        let recordData = try JSONEncoder().encode(record)
        try recordData.write(to: paths.buildRecordPath, options: .atomic)

        actor Counter {
            var value = 0

            func increment() {
                value += 1
            }

            func current() -> Int {
                value
            }
        }
        let counter = Counter()
        let runner = StubExcalidrawProcessRunner { _, _, _ in
            await counter.increment()
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
        let coordinator = ExcalidrawBuildCoordinator(processRunner: runner, fileManager: .default)

        let entrypoint = try await coordinator.ensureBuilt(manifest: manifest, paths: paths)
        let invocationCount = await counter.current()
        XCTAssertEqual(
            entrypoint.path,
            paths.sourceDirectory.appendingPathComponent(manifest.entrypoint, isDirectory: false).path
        )
        XCTAssertEqual(invocationCount, 0)
    }

    func testBuildCoordinatorUsesNonInteractiveShellForYarnCommands() async throws {
        let root = temporaryExcalidrawRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = ExcalidrawRuntimePaths(sessionID: UUID(), rootDirectoryOverride: root)
        let manifest = ExcalidrawBuildManifest.default

        actor InvocationRecorder {
            var values: [(String, [String], String?)] = []

            func append(_ value: (String, [String], String?)) {
                values.append(value)
            }

            func all() -> [(String, [String], String?)] {
                values
            }
        }

        let recorder = InvocationRecorder()

        let runner = StubExcalidrawProcessRunner { executable, arguments, currentDirectory in
            await recorder.append((executable, arguments, currentDirectory))

            if executable == "/usr/bin/which", let tool = arguments.first {
                return ProcessResult(exitCode: 0, stdout: "/usr/bin/\(tool)", stderr: "")
            }

            if executable == "/usr/bin/git", arguments.first == "clone" {
                try FileManager.default.createDirectory(at: paths.sourceDirectory, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(
                    at: paths.sourceDirectory.appendingPathComponent(".git", isDirectory: true),
                    withIntermediateDirectories: true
                )
            }

            if executable == "/bin/zsh",
               arguments.first == "-lc",
               arguments.count == 2,
               arguments[1].contains(manifest.buildCommand) {
                let artifact = paths.sourceDirectory.appendingPathComponent(manifest.entrypoint, isDirectory: false)
                try FileManager.default.createDirectory(at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: artifact)
            }

            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }

        let coordinator = ExcalidrawBuildCoordinator(processRunner: runner, fileManager: .default)
        _ = try await coordinator.ensureBuilt(manifest: manifest, paths: paths)

        let invocations = await recorder.all()
        let shellInvocations = invocations.filter { $0.0 == "/bin/zsh" }

        XCTAssertEqual(shellInvocations.count, 2)
        XCTAssertTrue(shellInvocations.allSatisfy { invocation in invocation.1.first == "-lc" })
        XCTAssertTrue(shellInvocations.allSatisfy { invocation in
            invocation.1.count == 2 &&
                invocation.1[1].contains("COREPACK_ENABLE_DOWNLOAD_PROMPT=0") &&
                invocation.1[1].contains("export CI=1")
        })
        XCTAssertTrue(shellInvocations.contains(where: { $0.1[1].contains(manifest.installCommand) }))
        XCTAssertTrue(shellInvocations.contains(where: { $0.1[1].contains(manifest.buildCommand) }))
    }

    func testSessionOriginStorePersistsPreferredPort() {
        let root = temporaryExcalidrawRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID()
        let paths = ExcalidrawRuntimePaths(sessionID: sessionID, rootDirectoryOverride: root)
        let store = ExcalidrawSessionOriginStore(recordURL: paths.originsRecordPath, portBase: 47_000, portSpan: 3_000)

        let preferred = store.preferredPort(for: sessionID)
        XCTAssertTrue((47_000..<50_000).contains(preferred))

        store.persistPort(55_555, for: sessionID)

        let reloaded = ExcalidrawSessionOriginStore(recordURL: paths.originsRecordPath, portBase: 47_000, portSpan: 3_000)
        XCTAssertEqual(reloaded.preferredPort(for: sessionID), 55_555)
    }

    private func temporaryExcalidrawRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx0-excalidraw-runtime-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private struct StubExcalidrawProcessRunner: ProcessRunnerProtocol {
    let block: @Sendable (String, [String], String?) async throws -> ProcessResult

    init(block: @escaping @Sendable (String, [String], String?) async throws -> ProcessResult) {
        self.block = block
    }

    func run(executable: String, arguments: [String], currentDirectory: String?) async throws -> ProcessResult {
        try await block(executable, arguments, currentDirectory)
    }
}
