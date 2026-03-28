import Foundation
@testable import idx0
import XCTest

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
    let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    let nodePath = binDirectory.appendingPathComponent("node", isDirectory: false)
    try writeExecutable("#!/bin/sh\nexit 0\n", to: nodePath)

    let runner = StubExcalidrawProcessRunner { executable, arguments, _ in
      if executable == "/usr/bin/which", let tool = arguments.first {
        switch tool {
        case "git":
          return ProcessResult(exitCode: 0, stdout: "/usr/bin/git", stderr: "")
        case "node":
          return ProcessResult(exitCode: 0, stdout: nodePath.path, stderr: "")
        case "yarn", "corepack":
          return ProcessResult(exitCode: 1, stdout: "", stderr: "not found")
        default:
          return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
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

      if executable == "/bin/zsh",
         arguments == ["-lc", "whence -p yarn"] || arguments == ["-ilc", "whence -p yarn"]
      {
        return ProcessResult(exitCode: 1, stdout: "", stderr: "not found")
      }

      if executable == "/bin/zsh",
         arguments == ["-lc", "whence -p corepack"] || arguments == ["-ilc", "whence -p corepack"]
      {
        return ProcessResult(exitCode: 1, stdout: "", stderr: "not found")
      }

      return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
    let coordinator = ExcalidrawBuildCoordinator(processRunner: runner, fileManager: .default)

    do {
      _ = try await coordinator.ensureBuilt(manifest: .default, paths: paths)
      XCTFail("Expected missing-tool error")
    } catch let error as ExcalidrawRuntimeError {
      guard case let .missingYarnPackageManager(resolvedNodePath) = error else {
        XCTFail("Unexpected Excalidraw runtime error: \(error)")
        return
      }
      XCTAssertEqual(resolvedNodePath, nodePath.path)
      XCTAssertEqual(
        error.errorDescription,
        """
        Excalidraw found Node.js at \(nodePath.path), but could not find `yarn` or `corepack`.
        Run `corepack enable` for that Node installation, or install Yarn, then retry.
        """
      )
    }
  }

  func testBuildCoordinatorReusesExistingArtifactsWithoutInvokingNodeOrYarnChecks() async throws {
    let root = temporaryExcalidrawRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = ExcalidrawRuntimePaths(sessionID: UUID(), rootDirectoryOverride: root)
    try paths.ensureBaseDirectories()
    try FileManager.default.createDirectory(at: paths.sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: paths.sourceDirectory.appendingPathComponent(".git", isDirectory: true),
      withIntermediateDirectories: true
    )

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
    let runner = StubExcalidrawProcessRunner { executable, arguments, _ in
      await recorder.append((executable, arguments))
      if executable == "/usr/bin/which", let tool = arguments.first {
        if tool == "node" || tool == "yarn" {
          XCTFail("Node/Yarn checks should be skipped when latest build artifacts are reusable")
        }
        return ProcessResult(exitCode: 0, stdout: "/usr/bin/\(tool)\n", stderr: "")
      }
      if executable == "/usr/bin/git", arguments.contains("rev-parse") {
        return ProcessResult(exitCode: 0, stdout: "\(resolvedSourceCommit)\n", stderr: "")
      }
      return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
    let coordinator = ExcalidrawBuildCoordinator(processRunner: runner, fileManager: .default)

    let entrypoint = try await coordinator.ensureBuilt(manifest: manifest, paths: paths)
    let invocations = await recorder.all()
    XCTAssertEqual(
      entrypoint.path,
      paths.sourceDirectory.appendingPathComponent(manifest.entrypoint, isDirectory: false).path
    )
    XCTAssertTrue(invocations.contains(where: { $0.0 == "/usr/bin/git" && $0.1.contains("fetch") }))
    XCTAssertFalse(invocations.contains(where: { $0.0 == "/usr/bin/git" && $0.1.contains("checkout") }))
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

      if executable == "/usr/bin/git", arguments.contains("rev-parse") {
        return ProcessResult(exitCode: 0, stdout: "abc123\n", stderr: "")
      }

      if executable == "/bin/zsh",
         arguments.first == "-lc",
         arguments.count == 2,
         arguments[1].contains("--cwd excalidraw-app build")
      {
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
    XCTAssertTrue(shellInvocations.contains(where: {
      $0.1[1].contains("/usr/bin/yarn") &&
        $0.1[1].contains("install --frozen-lockfile")
    }))
    XCTAssertTrue(shellInvocations.contains(where: {
      $0.1[1].contains("/usr/bin/yarn") &&
        $0.1[1].contains("--cwd excalidraw-app build")
    }))
  }

  func testBuildCoordinatorUsesResolvedGitPathForGitCommands() async throws {
    let root = temporaryExcalidrawRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = ExcalidrawRuntimePaths(sessionID: UUID(), rootDirectoryOverride: root)
    let manifest = ExcalidrawBuildManifest.default
    let resolvedGitPath = "/opt/homebrew/bin/git"

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
        switch tool {
        case "git":
          return ProcessResult(exitCode: 0, stdout: "\(resolvedGitPath)\n", stderr: "")
        case "node", "yarn":
          return ProcessResult(exitCode: 0, stdout: "/usr/bin/\(tool)\n", stderr: "")
        default:
          break
        }
      }

      if executable == resolvedGitPath, arguments.first == "clone" {
        try FileManager.default.createDirectory(at: paths.sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
          at: paths.sourceDirectory.appendingPathComponent(".git", isDirectory: true),
          withIntermediateDirectories: true
        )
      }

      if executable == resolvedGitPath, arguments.contains("rev-parse") {
        return ProcessResult(exitCode: 0, stdout: "abc123\n", stderr: "")
      }

      if executable == "/bin/zsh",
         arguments.first == "-lc",
         arguments.count == 2,
         arguments[1].contains("--cwd excalidraw-app build")
      {
        let artifact = paths.sourceDirectory.appendingPathComponent(manifest.entrypoint, isDirectory: false)
        try FileManager.default.createDirectory(at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: artifact)
      }

      return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    let coordinator = ExcalidrawBuildCoordinator(processRunner: runner, fileManager: .default)
    _ = try await coordinator.ensureBuilt(manifest: manifest, paths: paths)

    let invocations = await recorder.all()
    XCTAssertTrue(invocations.contains(where: { $0.0 == resolvedGitPath && $0.1.first == "clone" }))
    XCTAssertTrue(invocations.contains(where: { $0.0 == resolvedGitPath && $0.1.contains("checkout") }))
    XCTAssertFalse(invocations.contains(where: { $0.0 == "/usr/bin/git" }))
  }

  func testBuildCoordinatorFallsBackToAdjacentCorepackWhenYarnIsMissing() async throws {
    let root = temporaryExcalidrawRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let binDirectory = root.appendingPathComponent("node-bin", isDirectory: true)
    try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)

    let nodePath = binDirectory.appendingPathComponent("node", isDirectory: false)
    let corepackPath = binDirectory.appendingPathComponent("corepack", isDirectory: false)
    try writeExecutable("#!/bin/sh\nexit 0\n", to: nodePath)
    try writeExecutable("#!/bin/sh\nexit 0\n", to: corepackPath)

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
        switch tool {
        case "git":
          return ProcessResult(exitCode: 0, stdout: "/usr/bin/git\n", stderr: "")
        case "node", "yarn":
          return ProcessResult(exitCode: 1, stdout: "", stderr: "not found")
        default:
          return ProcessResult(exitCode: 1, stdout: "", stderr: "")
        }
      }

      if executable == "/bin/zsh", arguments == ["-lc", "whence -p node"] {
        return ProcessResult(exitCode: 1, stdout: "", stderr: "")
      }

      if executable == "/bin/zsh", arguments == ["-ilc", "whence -p node"] {
        return ProcessResult(
          exitCode: 0,
          stdout: """
          Dotfiles have changed remotely and locally:
          M zsh/.zshrc
          Seems unixorn/autoupdate-antigen.zshplugin is already installed!
          \(nodePath.path)
          """,
          stderr: ""
        )
      }

      if executable == "/bin/zsh",
         arguments == ["-lc", "whence -p yarn"] || arguments == ["-ilc", "whence -p yarn"]
      {
        return ProcessResult(
          exitCode: 1,
          stdout: """
          Dotfiles have changed remotely and locally:
          M zsh/.zshrc
          Seems unixorn/autoupdate-antigen.zshplugin is already installed!
          """,
          stderr: ""
        )
      }

      if executable == "/usr/bin/git", arguments.first == "clone" {
        try FileManager.default.createDirectory(at: paths.sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
          at: paths.sourceDirectory.appendingPathComponent(".git", isDirectory: true),
          withIntermediateDirectories: true
        )
      }

      if executable == "/usr/bin/git", arguments.contains("rev-parse") {
        return ProcessResult(exitCode: 0, stdout: "abc123\n", stderr: "")
      }

      if executable == "/bin/zsh",
         arguments.first == "-lc",
         arguments.count == 2,
         arguments[1].contains("yarn --cwd excalidraw-app build")
      {
        let artifact = paths.sourceDirectory.appendingPathComponent(manifest.entrypoint, isDirectory: false)
        try FileManager.default.createDirectory(at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: artifact)
      }

      return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    let coordinator = ExcalidrawBuildCoordinator(processRunner: runner, fileManager: .default)
    _ = try await coordinator.ensureBuilt(manifest: manifest, paths: paths)

    let invocations = await recorder.all()
    let shellInvocations = invocations.filter { $0.0 == "/bin/zsh" && $0.1.first == "-lc" }

    XCTAssertTrue(
      shellInvocations.contains(where: {
        $0.1.count == 2 &&
          $0.1[1].contains(corepackPath.path) &&
          $0.1[1].contains("yarn install --frozen-lockfile")
      })
    )
    XCTAssertTrue(
      shellInvocations.contains(where: {
        $0.1.count == 2 &&
          $0.1[1].contains(corepackPath.path) &&
          $0.1[1].contains("yarn --cwd excalidraw-app build")
      })
    )
  }

  func testSessionOriginStorePersistsPreferredPort() {
    let root = temporaryExcalidrawRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = UUID()
    let paths = ExcalidrawRuntimePaths(sessionID: sessionID, rootDirectoryOverride: root)
    let store = ExcalidrawSessionOriginStore(recordURL: paths.originsRecordPath, portBase: 47000, portSpan: 3000)

    let preferred = store.preferredPort(for: sessionID)
    XCTAssertTrue((47000 ..< 50000).contains(preferred))

    store.persistPort(55555, for: sessionID)

    let reloaded = ExcalidrawSessionOriginStore(recordURL: paths.originsRecordPath, portBase: 47000, portSpan: 3000)
    XCTAssertEqual(reloaded.preferredPort(for: sessionID), 55555)
  }

  func testSessionOriginStoreRemovePortPrunesSessionEntry() throws {
    let root = temporaryExcalidrawRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    struct OriginRecordMirror: Codable {
      var portsBySessionID: [String: Int]
    }

    let firstSessionID = UUID()
    let secondSessionID = UUID()
    let paths = ExcalidrawRuntimePaths(sessionID: firstSessionID, rootDirectoryOverride: root)
    let store = ExcalidrawSessionOriginStore(recordURL: paths.originsRecordPath, portBase: 47000, portSpan: 3000)

    store.persistPort(55001, for: firstSessionID)
    store.persistPort(55002, for: secondSessionID)
    store.removePort(for: firstSessionID)

    let data = try Data(contentsOf: paths.originsRecordPath)
    let record = try JSONDecoder().decode(OriginRecordMirror.self, from: data)

    XCTAssertNil(record.portsBySessionID[firstSessionID.uuidString])
    XCTAssertEqual(record.portsBySessionID[secondSessionID.uuidString], 55002)
  }

  private func temporaryExcalidrawRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("idx0-excalidraw-runtime-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func writeExecutable(_ content: String, to path: URL) throws {
    try content.write(to: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
  }
}

private struct StubExcalidrawProcessRunner: ProcessRunnerProtocol {
  let block: @Sendable (String, [String], String?) async throws -> ProcessResult

  func run(executable: String, arguments: [String], currentDirectory: String?) async throws -> ProcessResult {
    try await block(executable, arguments, currentDirectory)
  }
}
