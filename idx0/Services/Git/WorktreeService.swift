import Foundation

enum WorktreeServiceError: LocalizedError {
    case invalidFolder
    case invalidBranchName
    case invalidWorktreePath
    case worktreeNotFound
    case worktreeDirty
    case createFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidFolder:
            return "The selected folder is invalid."
        case .invalidBranchName:
            return "Branch name cannot be empty."
        case .invalidWorktreePath:
            return "The selected worktree path is invalid."
        case .worktreeNotFound:
            return "That worktree does not belong to the selected repository."
        case .worktreeDirty:
            return "Worktree has local changes. Clean it before deletion."
        case .createFailed(let message):
            return message
        }
    }
}

protocol WorktreeServiceProtocol {
    func validateRepo(path: String) async throws -> GitRepoInfo
    func createWorktree(repoPath: String, branchName: String?, sessionTitle: String?) async throws -> WorktreeInfo
    func attachExistingWorktree(repoPath: String, worktreePath: String) async throws -> WorktreeInfo
    func listWorktrees(repoPath: String) async throws -> [WorktreeInfo]
    func inspectWorktree(repoPath: String, worktreePath: String) async throws -> WorktreeState
    func deleteWorktreeIfClean(repoPath: String, worktreePath: String) async throws
}

struct WorktreeService: WorktreeServiceProtocol {
    private let gitService: GitServiceProtocol
    private let paths: FileSystemPaths
    private let fileManager: FileManager
    private let worktreeNameGenerator: () -> String

    init(
        gitService: GitServiceProtocol,
        paths: FileSystemPaths,
        fileManager: FileManager = .default,
        worktreeNameGenerator: @escaping () -> String = {
            String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        }
    ) {
        self.gitService = gitService
        self.paths = paths
        self.fileManager = fileManager
        self.worktreeNameGenerator = worktreeNameGenerator
    }

    func validateRepo(path: String) async throws -> GitRepoInfo {
        try await gitService.repoInfo(for: path)
    }

    func listWorktrees(repoPath: String) async throws -> [WorktreeInfo] {
        try await gitService.listWorktrees(repoPath: repoPath)
    }

    func attachExistingWorktree(repoPath: String, worktreePath: String) async throws -> WorktreeInfo {
        let info = try await gitService.repoInfo(for: repoPath)
        let normalizedPath = URL(fileURLWithPath: worktreePath).standardizedFileURL.path

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorktreeServiceError.invalidWorktreePath
        }

        let worktrees = try await gitService.listWorktrees(repoPath: info.topLevelPath)
        guard let match = worktrees.first(where: {
            URL(fileURLWithPath: $0.worktreePath).standardizedFileURL.path == normalizedPath
        }) else {
            throw WorktreeServiceError.worktreeNotFound
        }

        return WorktreeInfo(
            repoPath: info.topLevelPath,
            worktreePath: match.worktreePath,
            branchName: match.branchName
        )
    }

    func createWorktree(repoPath: String, branchName: String?, sessionTitle: String?) async throws -> WorktreeInfo {
        let info = try await gitService.repoInfo(for: repoPath)

        let resolvedBranch: String
        if let branchName,
           !branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedBranch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            resolvedBranch = BranchNameGenerator.generate(
                sessionTitle: sessionTitle,
                repoName: info.repoName
            )
        }

        guard !resolvedBranch.isEmpty else {
            throw WorktreeServiceError.invalidBranchName
        }

        ensureIDX0ExcludedInLocalRepo(repoTopLevelPath: info.topLevelPath)

        let worktreePath: String
        do {
            worktreePath = try uniqueWorktreePath(repoTopLevelPath: info.topLevelPath)
        } catch {
            throw WorktreeServiceError.createFailed("Unable to prepare workspace worktree directory: \(error.localizedDescription)")
        }

        do {
            return try await gitService.createWorktree(
                repoPath: info.topLevelPath,
                branchName: resolvedBranch,
                worktreePath: worktreePath
            )
        } catch {
            throw WorktreeServiceError.createFailed(error.localizedDescription)
        }
    }

    func inspectWorktree(repoPath: String, worktreePath: String) async throws -> WorktreeState {
        let info = try await gitService.repoInfo(for: repoPath)
        let normalizedPath = URL(fileURLWithPath: worktreePath).standardizedFileURL.path

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .missingOnDisk
        }

        let worktrees = try await gitService.listWorktrees(repoPath: info.topLevelPath)
        guard worktrees.contains(where: {
            URL(fileURLWithPath: $0.worktreePath).standardizedFileURL.path == normalizedPath
        }) else {
            throw WorktreeServiceError.worktreeNotFound
        }

        let status = try await gitService.statusPorcelain(path: normalizedPath)
        return status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .clean : .dirty
    }

    func deleteWorktreeIfClean(repoPath: String, worktreePath: String) async throws {
        let state = try await inspectWorktree(repoPath: repoPath, worktreePath: worktreePath)
        switch state {
        case .clean:
            let info = try await gitService.repoInfo(for: repoPath)
            try await gitService.removeWorktree(
                repoPath: info.topLevelPath,
                worktreePath: URL(fileURLWithPath: worktreePath).standardizedFileURL.path
            )
        case .dirty:
            throw WorktreeServiceError.worktreeDirty
        case .missingOnDisk:
            throw WorktreeServiceError.invalidWorktreePath
        default:
            throw WorktreeServiceError.worktreeNotFound
        }
    }

    private func uniqueWorktreePath(repoTopLevelPath: String) throws -> String {
        let root = try workspaceWorktreesDirectoryURL(repoTopLevelPath: repoTopLevelPath)
        let baseName = "wt-\(sanitizedWorktreeToken(worktreeNameGenerator()))"
        var candidate = root.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2

        while fileManager.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
            suffix += 1
        }

        return candidate.path
    }

    private func workspaceWorktreesDirectoryURL(repoTopLevelPath: String) throws -> URL {
        let root = URL(fileURLWithPath: repoTopLevelPath)
            .standardizedFileURL
            .appendingPathComponent(".idx0", isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func sanitizedWorktreeToken(_ rawValue: String) -> String {
        let token = rawValue.lowercased().filter { character in
            ("a"..."z").contains(character) || ("0"..."9").contains(character)
        }
        if !token.isEmpty {
            return String(token.prefix(12))
        }
        return String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    private func ensureIDX0ExcludedInLocalRepo(repoTopLevelPath: String) {
        guard let excludeFileURL = localGitExcludeURL(repoTopLevelPath: repoTopLevelPath) else {
            return
        }

        do {
            try fileManager.createDirectory(
                at: excludeFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let existing = (try? String(contentsOf: excludeFileURL, encoding: .utf8)) ?? ""
            let entries = existing
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !entries.contains(".idx0/") else { return }

            var updated = existing
            if !updated.isEmpty, !updated.hasSuffix("\n") {
                updated.append("\n")
            }
            updated.append(".idx0/\n")
            try updated.write(to: excludeFileURL, atomically: true, encoding: .utf8)
        } catch {
            Logger.error("Failed to update local git exclude for .idx0/: \(error.localizedDescription)")
        }
    }

    private func localGitExcludeURL(repoTopLevelPath: String) -> URL? {
        guard let gitDirectory = gitDirectoryURL(repoTopLevelPath: repoTopLevelPath) else {
            return nil
        }
        return gitDirectory
            .appendingPathComponent("info", isDirectory: true)
            .appendingPathComponent("exclude", isDirectory: false)
    }

    private func gitDirectoryURL(repoTopLevelPath: String) -> URL? {
        let repoURL = URL(fileURLWithPath: repoTopLevelPath).standardizedFileURL
        let dotGitURL = repoURL.appendingPathComponent(".git", isDirectory: false)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dotGitURL.path, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue {
            return dotGitURL
        }

        guard let dotGitContents = try? String(contentsOf: dotGitURL, encoding: .utf8),
              let directiveLine = dotGitContents
                .components(separatedBy: .newlines)
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else {
            return nil
        }

        let trimmed = directiveLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("gitdir:") else { return nil }

        let rawPath = String(trimmed.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return nil }

        let resolved: URL
        if rawPath.hasPrefix("/") {
            resolved = URL(fileURLWithPath: rawPath, isDirectory: true)
        } else {
            resolved = repoURL.appendingPathComponent(rawPath, isDirectory: true)
        }
        return resolved.standardizedFileURL
    }
}
