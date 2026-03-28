import Foundation
import XCTest
@testable import idx0

@MainActor
final class T3CodeRuntimeTests: XCTestCase {
    func testPrepareSessionSnapshotCreatesStateDirectory() throws {
        let root = temporaryT3Root()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID()
        let paths = T3RuntimePaths(sessionID: sessionID, rootDirectoryOverride: root)
        let manager = T3StateSnapshotManager()

        defer {
            manager.removeSessionSnapshot(paths: paths)
            try? FileManager.default.removeItem(at: root)
        }

        let stateURL = try manager.prepareSessionSnapshot(paths: paths)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: stateURL.path, isDirectory: &isDirectory)

        XCTAssertTrue(exists)
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(stateURL.path, paths.sessionStateDirectory.path)
    }

    func testRemoveSessionSnapshotDeletesSessionDirectory() throws {
        let root = temporaryT3Root()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID()
        let paths = T3RuntimePaths(sessionID: sessionID, rootDirectoryOverride: root)
        let manager = T3StateSnapshotManager()
        try paths.ensureBaseDirectories()
        try FileManager.default.createDirectory(at: paths.sessionStateDirectory, withIntermediateDirectories: true)
        let marker = paths.sessionStateDirectory.appendingPathComponent("marker.txt", isDirectory: false)
        try "marker".write(to: marker, atomically: true, encoding: .utf8)

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        manager.removeSessionSnapshot(paths: paths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.sessionDirectory.path))
    }

    func testT3TileRuntimeStateDisplayMessagesAreStable() {
        XCTAssertEqual(T3TileRuntimeState.idle.displayMessage, "Ready")
        XCTAssertEqual(T3TileRuntimeState.preparingSource.displayMessage, "Preparing T3 Code source...")
        XCTAssertEqual(T3TileRuntimeState.building.displayMessage, "Building T3 Code...")
        XCTAssertEqual(T3TileRuntimeState.starting.displayMessage, "Starting T3 Code...")
        XCTAssertEqual(T3TileRuntimeState.live(urlString: "http://127.0.0.1:9999").displayMessage, "Live")
    }

    func testManifestNormalizesLegacyRepositoryAndBuildCommand() {
        let legacy = T3BuildManifest(
            repositoryURL: "https://github.com/t3dotgg/t3.chat.git",
            pinnedCommit: "abc123",
            installCommand: "bun install --frozen-lockfile",
            buildCommand: "bun run --cwd apps/server build",
            entrypoint: "apps/server/dist/index.cjs",
            requiredArtifacts: [
                "apps/server/dist/index.cjs",
                "apps/server/dist/client/index.html"
            ]
        )

        let normalized = legacy.normalized()
        XCTAssertEqual(normalized.repositoryURL, T3BuildManifest.canonicalRepositoryURL)
        XCTAssertEqual(normalized.buildCommand, T3BuildManifest.canonicalBuildCommand)
        XCTAssertEqual(normalized.entrypoint, T3BuildManifest.canonicalEntrypoint)
        XCTAssertTrue(normalized.requiredArtifacts.contains(T3BuildManifest.canonicalEntrypoint))
        XCTAssertFalse(normalized.requiredArtifacts.contains("apps/server/dist/index.cjs"))
    }

    func testBuildCoordinatorFailsWhenBunMissing() async throws {
        let root = temporaryT3Root()
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = T3RuntimePaths(sessionID: UUID(), rootDirectoryOverride: root)
        let runner = StubProcessRunner { executable, arguments, _ in
            if executable == "/usr/bin/which", let tool = arguments.first {
                if tool == "bun" {
                    return ProcessResult(exitCode: 1, stdout: "", stderr: "not found")
                }
                return ProcessResult(exitCode: 0, stdout: "/usr/bin/\(tool)", stderr: "")
            }

            if executable == "/usr/bin/git", arguments.first == "clone" {
                try FileManager.default.createDirectory(at: paths.sourceDirectory, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(
                    at: paths.sourceDirectory.appendingPathComponent(".git", isDirectory: true),
                    withIntermediateDirectories: true
                )
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }

            if executable == "/usr/bin/git", arguments.contains("rev-parse") {
                return ProcessResult(exitCode: 0, stdout: "abc123\n", stderr: "")
            }

            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
        let coordinator = T3BuildCoordinator(processRunner: runner, fileManager: .default)

        do {
            _ = try await coordinator.ensureBuilt(manifest: .default, paths: paths)
            XCTFail("Expected missing-tool error")
        } catch let error as T3RuntimeError {
            guard case .missingTool(let name) = error else {
                XCTFail("Unexpected T3 runtime error: \(error)")
                return
            }
            XCTAssertEqual(name, "bun")
        }
    }

    func testBuildCoordinatorReusesExistingArtifactsWithoutInvokingNodeOrBunChecks() async throws {
        let root = temporaryT3Root()
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = T3RuntimePaths(sessionID: UUID(), rootDirectoryOverride: root)
        try paths.ensureBaseDirectories()
        try FileManager.default.createDirectory(at: paths.sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: paths.sourceDirectory.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )

        let manifest = T3BuildManifest(
            repositoryURL: "https://example.com/unused.git",
            pinnedCommit: "abc123",
            installCommand: "unused",
            buildCommand: "unused",
            entrypoint: "apps/server/dist/index.mjs",
            requiredArtifacts: [
                "apps/server/dist/index.mjs",
                "apps/server/dist/client/index.html"
            ]
        )

        for artifact in manifest.requiredArtifacts {
            let artifactURL = paths.sourceDirectory.appendingPathComponent(artifact, isDirectory: false)
            try FileManager.default.createDirectory(at: artifactURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: artifactURL)
        }

        struct BuildRecordMirror: Codable {
            let sourceCommit: String
            let entrypoint: String
            let builtAt: Date
        }

        let resolvedSourceCommit = "abc123"
        let record = BuildRecordMirror(
            sourceCommit: resolvedSourceCommit,
            entrypoint: manifest.entrypoint,
            builtAt: Date()
        )
        let recordData = try JSONEncoder().encode(record)
        try recordData.write(to: paths.buildRecordPath, options: .atomic)

        actor InvocationRecorder {
            var values: [(String, [String])] = []

            func append(_ value: (String, [String])) {
                values.append(value)
            }

            func all() -> [(String, [String])] {
                values
            }
        }

        let recorder = InvocationRecorder()
        let runner = StubProcessRunner { executable, arguments, _ in
            await recorder.append((executable, arguments))
            if executable == "/usr/bin/which", let tool = arguments.first {
                if tool == "node" || tool == "bun" {
                    XCTFail("Node/Bun checks should be skipped when latest build artifacts are reusable")
                }
                return ProcessResult(exitCode: 0, stdout: "/usr/bin/\(tool)\n", stderr: "")
            }

            if executable == "/usr/bin/git", arguments.contains("rev-parse") {
                return ProcessResult(exitCode: 0, stdout: "\(resolvedSourceCommit)\n", stderr: "")
            }

            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
        let coordinator = T3BuildCoordinator(processRunner: runner, fileManager: .default)

        let entrypoint = try await coordinator.ensureBuilt(manifest: manifest, paths: paths)
        let invocations = await recorder.all()
        XCTAssertEqual(entrypoint.path, paths.sourceDirectory.appendingPathComponent(manifest.entrypoint, isDirectory: false).path)
        XCTAssertTrue(invocations.contains(where: { $0.0 == "/usr/bin/git" && $0.1.contains("fetch") }))
        XCTAssertFalse(invocations.contains(where: { $0.0 == "/usr/bin/git" && $0.1.contains("checkout") }))
    }

    private func temporaryT3Root() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx0-t3-runtime-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private struct StubProcessRunner: ProcessRunnerProtocol {
    let block: @Sendable (String, [String], String?) async throws -> ProcessResult

    init(block: @escaping @Sendable (String, [String], String?) async throws -> ProcessResult) {
        self.block = block
    }

    func run(executable: String, arguments: [String], currentDirectory: String?) async throws -> ProcessResult {
        try await block(executable, arguments, currentDirectory)
    }
}
