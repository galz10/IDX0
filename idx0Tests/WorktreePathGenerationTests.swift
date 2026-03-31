import Foundation
@testable import idx0
import XCTest

final class WorktreePathGenerationTests: XCTestCase {
  func testCreateWorktreeUsesWorkspaceLocalPathAndAppendsCollisionSuffix() async throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("idx0-worktree-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let paths = try makePaths(root: temp)
    let repoRoot = try makeRepoRoot(at: temp, name: "repo")
    let git = MockGitService()
    let service = WorktreeService(
      gitService: git,
      paths: paths,
      worktreeNameGenerator: { "collision-name" }
    )

    let first = try await service.createWorktree(repoPath: repoRoot.path, branchName: "idx0/fix", sessionTitle: "Fix")

    try FileManager.default.createDirectory(atPath: first.worktreePath, withIntermediateDirectories: true)

    let second = try await service.createWorktree(repoPath: repoRoot.path, branchName: "idx0/fix-2", sessionTitle: "Fix")

    let createdPaths = git.createdWorktreePaths
    XCTAssertEqual(createdPaths.count, 2)
    XCTAssertEqual(URL(fileURLWithPath: first.worktreePath).lastPathComponent, "wt-collisionnam")
    XCTAssertEqual(URL(fileURLWithPath: second.worktreePath).lastPathComponent, "wt-collisionnam-2")

    let expectedPrefix = repoRoot
      .appendingPathComponent(".idx0/worktrees", isDirectory: true)
      .path + "/"
    XCTAssertTrue(first.worktreePath.hasPrefix(expectedPrefix))
    XCTAssertTrue(second.worktreePath.hasPrefix(expectedPrefix))
  }

  func testCreateWorktreeAddsIDX0RuleToLocalExcludeIdempotently() async throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("idx0-worktree-exclude-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let paths = try makePaths(root: temp)
    let repoRoot = try makeRepoRoot(at: temp, name: "repo")
    let excludeURL = repoRoot.appendingPathComponent(".git/info/exclude", isDirectory: false)
    try "existing-rule\n".write(to: excludeURL, atomically: true, encoding: .utf8)

    let git = MockGitService()
    let service = WorktreeService(
      gitService: git,
      paths: paths,
      worktreeNameGenerator: { "idempotent" }
    )

    _ = try await service.createWorktree(repoPath: repoRoot.path, branchName: "idx0/one", sessionTitle: "One")
    _ = try await service.createWorktree(repoPath: repoRoot.path, branchName: "idx0/two", sessionTitle: "Two")

    let exclude = try String(contentsOf: excludeURL, encoding: .utf8)
    let normalizedLines = exclude
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    XCTAssertEqual(normalizedLines.count(where: { $0 == ".idx0/" }), 1)
  }

  func testCreateWorktreeUpdatesExcludeWhenDotGitIsFile() async throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("idx0-worktree-dotgit-file-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let paths = try makePaths(root: temp)
    let repoRoot = temp.appendingPathComponent("repo", isDirectory: true)
    try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)

    let actualGitDir = temp.appendingPathComponent("shared-git-dir", isDirectory: true)
    let infoDir = actualGitDir.appendingPathComponent("info", isDirectory: true)
    try FileManager.default.createDirectory(at: infoDir, withIntermediateDirectories: true)
    let excludeURL = infoDir.appendingPathComponent("exclude", isDirectory: false)
    try "header\n".write(to: excludeURL, atomically: true, encoding: .utf8)
    try "gitdir: \(actualGitDir.path)\n".write(
      to: repoRoot.appendingPathComponent(".git", isDirectory: false),
      atomically: true,
      encoding: .utf8
    )

    let git = MockGitService()
    let service = WorktreeService(
      gitService: git,
      paths: paths,
      worktreeNameGenerator: { "dotgitfile" }
    )

    _ = try await service.createWorktree(repoPath: repoRoot.path, branchName: "idx0/dotgit", sessionTitle: "DotGit")

    let exclude = try String(contentsOf: excludeURL, encoding: .utf8)
    let normalizedLines = exclude
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    XCTAssertEqual(normalizedLines.count(where: { $0 == ".idx0/" }), 1)
  }

  func testDeleteWorktreeIfCleanRemovesThroughGit() async throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("idx0-worktree-delete-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let paths = try makePaths(root: temp)
    let git = MockGitService()
    let service = WorktreeService(gitService: git, paths: paths)

    let repoPath = "/tmp/repo-clean"
    let worktreePath = temp.appendingPathComponent("wt-clean", isDirectory: true).path
    try FileManager.default.createDirectory(atPath: worktreePath, withIntermediateDirectories: true)

    git.listedWorktrees = [WorktreeInfo(repoPath: repoPath, worktreePath: worktreePath, branchName: "main")]
    git.statusOutput = ""

    try await service.deleteWorktreeIfClean(repoPath: repoPath, worktreePath: worktreePath)
    XCTAssertEqual(git.removedWorktreePaths, [worktreePath])
  }

  func testDeleteWorktreeIfCleanThrowsWhenDirty() async throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("idx0-worktree-dirty-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let paths = try makePaths(root: temp)
    let git = MockGitService()
    let service = WorktreeService(gitService: git, paths: paths)

    let repoPath = "/tmp/repo-dirty"
    let worktreePath = temp.appendingPathComponent("wt-dirty", isDirectory: true).path
    try FileManager.default.createDirectory(atPath: worktreePath, withIntermediateDirectories: true)

    git.listedWorktrees = [WorktreeInfo(repoPath: repoPath, worktreePath: worktreePath, branchName: "main")]
    git.statusOutput = " M changed.swift"

    do {
      try await service.deleteWorktreeIfClean(repoPath: repoPath, worktreePath: worktreePath)
      XCTFail("Expected dirty worktree error")
    } catch let error as WorktreeServiceError {
      switch error {
      case .worktreeDirty:
        break
      default:
        XCTFail("Unexpected worktree error: \(error)")
      }
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private func makePaths(root: URL) throws -> FileSystemPaths {
    let appSupport = root.appendingPathComponent("AppSupport", isDirectory: true)
    try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

    return FileSystemPaths(
      appSupportDirectory: appSupport,
      sessionsFile: appSupport.appendingPathComponent("sessions.json"),
      projectsFile: appSupport.appendingPathComponent("projects.json"),
      inboxFile: appSupport.appendingPathComponent("inbox.json"),
      settingsFile: appSupport.appendingPathComponent("settings.json"),
      runDirectory: appSupport.appendingPathComponent("run", isDirectory: true),
      tempDirectory: appSupport.appendingPathComponent("temp", isDirectory: true),
      worktreesDirectory: appSupport.appendingPathComponent("worktrees", isDirectory: true)
    )
  }

  private func makeRepoRoot(at root: URL, name: String) throws -> URL {
    let repoRoot = root.appendingPathComponent(name, isDirectory: true)
    let infoDir = repoRoot
      .appendingPathComponent(".git", isDirectory: true)
      .appendingPathComponent("info", isDirectory: true)
    try FileManager.default.createDirectory(at: infoDir, withIntermediateDirectories: true)
    return repoRoot
  }
}

private final class MockGitService: GitServiceProtocol {
  var createdWorktreePaths: [String] = []
  var removedWorktreePaths: [String] = []
  var listedWorktrees: [WorktreeInfo] = []
  var statusOutput = ""

  func repoInfo(for path: String) async throws -> GitRepoInfo {
    GitRepoInfo(topLevelPath: path, currentBranch: "main", repoName: "repo")
  }

  func currentBranch(repoPath: String) async throws -> String? {
    _ = repoPath
    return "main"
  }

  func currentCommitSHA(repoPath: String) async throws -> String? {
    _ = repoPath
    return String(repeating: "a", count: 40)
  }

  func localBranches(repoPath: String) async throws -> [String] {
    _ = repoPath
    return ["main"]
  }

  func listWorktrees(repoPath: String) async throws -> [WorktreeInfo] {
    _ = repoPath
    return listedWorktrees
  }

  func createWorktree(repoPath: String, branchName: String, worktreePath: String) async throws -> WorktreeInfo {
    _ = repoPath
    _ = branchName
    createdWorktreePaths.append(worktreePath)
    return WorktreeInfo(repoPath: repoPath, worktreePath: worktreePath, branchName: branchName)
  }

  func statusPorcelain(path: String) async throws -> String {
    _ = path
    return statusOutput
  }

  func removeWorktree(repoPath: String, worktreePath: String) async throws {
    _ = repoPath
    removedWorktreePaths.append(worktreePath)
  }

  func diffNameStatus(path: String) async throws -> [ChangedFileSummary] {
    _ = path
    return []
  }

  func diffNameStatus(path: String, between leftRef: String, and rightRef: String) async throws -> [ChangedFileSummary] {
    _ = path
    _ = leftRef
    _ = rightRef
    return []
  }

  func diffStat(path: String) async throws -> DiffStat? {
    _ = path
    return DiffStat(filesChanged: 0, additions: 0, deletions: 0)
  }

  func diffStat(path: String, between leftRef: String, and rightRef: String) async throws -> DiffStat? {
    _ = path
    _ = leftRef
    _ = rightRef
    return DiffStat(filesChanged: 0, additions: 0, deletions: 0)
  }
}
