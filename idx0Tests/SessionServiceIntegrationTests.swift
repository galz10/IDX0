import Darwin
import Foundation
import XCTest
@testable import idx0

@MainActor
final class SessionServiceIntegrationTests: XCTestCase {
    func testCreateRepoBackedSessionWithoutWorktreeWhenSettingDisabled() async throws {
        let root = try makeTempRoot(prefix: "idx0-integration-repo")
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = try makeGitRepo(root: root, name: "repo")
        let branch = try currentBranch(at: repo.path)
        let service = try makeService(root: root)
        service.saveSettings { $0.defaultCreateWorktreeForRepoSessions = false }

        let result = try await service.createSession(from: SessionCreationRequest(
            title: "Repo Session",
            repoPath: repo.path,
            createWorktree: false,
            branchName: nil,
            existingWorktreePath: nil,
            shellPath: nil
        ))

        XCTAssertNil(result.worktree)
        XCTAssertEqual(canonicalPath(result.session.repoPath), canonicalPath(repo.path))
        XCTAssertEqual(result.session.branchName, branch)
        XCTAssertFalse(result.session.isWorktreeBacked)
        XCTAssertNil(result.session.worktreePath)

        try await Task.sleep(nanoseconds: 300_000_000)
    }

    func testCreateRepoBackedSessionCreatesWorktreeByDefaultWhenSettingEnabled() async throws {
        let root = try makeTempRoot(prefix: "idx0-integration-repo-default-worktree")
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = try makeGitRepo(root: root, name: "repo")
        let service = try makeService(root: root)
        service.saveSettings { $0.defaultCreateWorktreeForRepoSessions = true }

        let result = try await service.createSession(from: SessionCreationRequest(
            title: "Repo Session",
            repoPath: repo.path,
            createWorktree: false,
            branchName: nil,
            existingWorktreePath: nil,
            shellPath: nil
        ))

        XCTAssertTrue(result.session.isWorktreeBacked)
        XCTAssertNotNil(result.session.worktreePath)
        XCTAssertNotNil(result.worktree)
        if let worktreePath = result.session.worktreePath {
            XCTAssertTrue(worktreePath.hasPrefix(repo.path + "/.idx0/worktrees/"))
        }
    }

    func testCreateWorktreeBackedSessionFromGitRepo() async throws {
        let root = try makeTempRoot(prefix: "idx0-integration-worktree")
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = try makeGitRepo(root: root, name: "repo")
        let service = try makeService(root: root)
        let branch = "idx0/integration-\(UUID().uuidString.prefix(8))"

        let result = try await service.createSession(from: SessionCreationRequest(
            title: "Worktree Session",
            repoPath: repo.path,
            createWorktree: true,
            branchName: branch,
            existingWorktreePath: nil,
            shellPath: nil
        ))

        guard let worktreePath = result.session.worktreePath else {
            XCTFail("Expected worktree path")
            return
        }

        XCTAssertTrue(result.session.isWorktreeBacked)
        XCTAssertEqual(result.session.branchName, branch)
        XCTAssertEqual(result.worktree?.branchName, branch)
        XCTAssertEqual(result.worktree?.worktreePath, worktreePath)
        XCTAssertTrue(worktreePath.hasPrefix(repo.path + "/.idx0/worktrees/"))

        let worktreeName = URL(fileURLWithPath: worktreePath).lastPathComponent
        let pattern = #"^wt-[a-z0-9]{12}(?:-[0-9]+)?$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: worktreeName.utf16.count)
        XCTAssertNotNil(regex.firstMatch(in: worktreeName, options: [], range: range))

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        let worktreeList = try runGit(["worktree", "list", "--porcelain"], currentDirectory: repo.path)
        XCTAssertTrue(worktreeList.contains(worktreePath))
        let status = try runGit(["status", "--short"], currentDirectory: repo.path)
        XCTAssertFalse(status.contains(".idx0/"))
        XCTAssertTrue(status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        try await Task.sleep(nanoseconds: 300_000_000)
    }

    func testAttachExistingWorktreeSessionFromGitRepo() async throws {
        let root = try makeTempRoot(prefix: "idx0-integration-attach-worktree")
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = try makeGitRepo(root: root, name: "repo")
        let service = try makeService(root: root)
        let branch = "idx0/attach-\(UUID().uuidString.prefix(8))"
        let existingWorktreePath = root
            .appendingPathComponent("attached-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .path

        _ = try runGit(
            ["worktree", "add", existingWorktreePath, "-b", branch],
            currentDirectory: repo.path
        )

        let result = try await service.createSession(from: SessionCreationRequest(
            title: "Attach Existing",
            repoPath: repo.path,
            createWorktree: true,
            branchName: nil,
            existingWorktreePath: existingWorktreePath,
            shellPath: nil
        ))

        XCTAssertTrue(result.session.isWorktreeBacked)
        XCTAssertEqual(canonicalPath(result.session.repoPath), canonicalPath(repo.path))
        XCTAssertEqual(canonicalPath(result.session.worktreePath), canonicalPath(existingWorktreePath))
        XCTAssertEqual(result.session.branchName, branch)
        XCTAssertEqual(canonicalPath(result.worktree?.worktreePath), canonicalPath(existingWorktreePath))
    }

    func testRestoresPersistedSessionsAndSelection() async throws {
        let root = try makeTempRoot(prefix: "idx0-integration-restore")
        defer { try? FileManager.default.removeItem(at: root) }

        let service = try makeService(root: root)

        let first = try await service.createSession(from: SessionCreationRequest(
            title: "First",
            repoPath: nil,
            createWorktree: false,
            branchName: nil,
            existingWorktreePath: nil,
            shellPath: nil
        )).session

        _ = try await service.createSession(from: SessionCreationRequest(
            title: "Second",
            repoPath: nil,
            createWorktree: false,
            branchName: nil,
            existingWorktreePath: nil,
            shellPath: nil
        )).session

        service.selectSession(first.id)

        // Session writes are debounced in SessionService.
        try await Task.sleep(nanoseconds: 500_000_000)

        let restored = try makeService(root: root)
        XCTAssertEqual(restored.sessions.count, 2)
        XCTAssertEqual(restored.selectedSessionID, first.id)
    }

    func testInboxItemCreationAndResolution() async throws {
        let root = try makeTempRoot(prefix: "idx0-integration-inbox")
        defer { try? FileManager.default.removeItem(at: root) }

        let service = try makeService(root: root)
        let first = try await service.createSession(from: SessionCreationRequest(title: "First")).session
        _ = try await service.createSession(from: SessionCreationRequest(title: "Second")).session

        service.injectAttention(sessionID: first.id, reason: .needsInput, message: "Review needed")
        XCTAssertEqual(service.unresolvedAttentionItems.count, 1)
        XCTAssertEqual(service.unresolvedAttentionItems.first?.sessionID, first.id)

        service.selectSession(first.id)
        XCTAssertTrue(service.unresolvedAttentionItems.isEmpty)
    }

    func testBrowserPaneStateReloadAndControllerCreation() async throws {
        let root = try makeTempRoot(prefix: "idx0-integration-browser")
        defer { try? FileManager.default.removeItem(at: root) }

        let service = try makeService(root: root)
        let session = try await service.createSession(from: SessionCreationRequest(title: "Browser")).session
        service.toggleBrowserSplit(for: session.id)
        service.setBrowserURL(for: session.id, urlString: "https://example.com")

        try await Task.sleep(nanoseconds: 500_000_000)

        let restored = try makeService(root: root)
        let restoredSession = restored.sessions.first(where: { $0.id == session.id })
        XCTAssertEqual(restoredSession?.browserState?.isVisible, true)
        XCTAssertEqual(URL(string: restoredSession?.browserState?.currentURL ?? "")?.host, "example.com")
        XCTAssertNotNil(restored.controller(for: session.id))
        XCTAssertNotNil(restored.browserController(for: session.id))
    }

    func testIPCServerRequestResponseRoundTrip() throws {
        let socketPath = shortSocketPath()
        defer { unlink(socketPath) }

        let server = IPCServer(socketPath: socketPath) { request in
            IPCResponse(
                success: request.command == "ping",
                message: request.command == "ping" ? "pong" : "bad command",
                data: ["echo": request.payload["value"] ?? ""]
            )
        }
        server.start()
        defer { server.stop() }

        waitForSocket(path: socketPath, timeout: 2.0)

        let response = try sendIPCRequest(
            socketPath: socketPath,
            request: IPCRequest(command: "ping", payload: ["value": "hello"])
        )
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.message, "pong")
        XCTAssertEqual(response.data?["echo"], "hello")
    }

    private func shortSocketPath() -> String {
        let suffix = UUID().uuidString.prefix(8)
        return "/tmp/idx0-\(suffix).sock"
    }

    private func makeService(root: URL) throws -> SessionService {
        let paths = try makePaths(root: root)
        let gitService = GitService()
        let worktreeService = WorktreeService(gitService: gitService, paths: paths)
        return SessionService(
            sessionStore: SessionStore(url: paths.sessionsFile),
            projectStore: ProjectStore(url: paths.projectsFile),
            inboxStore: InboxStore(url: paths.inboxFile),
            settingsStore: SettingsStore(url: paths.settingsFile),
            worktreeService: worktreeService,
            host: .shared
        )
    }

    private func makePaths(root: URL) throws -> FileSystemPaths {
        let appSupport = root.appendingPathComponent("AppSupport", isDirectory: true)
        let paths = FileSystemPaths(
            appSupportDirectory: appSupport,
            sessionsFile: appSupport.appendingPathComponent("sessions.json"),
            projectsFile: appSupport.appendingPathComponent("projects.json"),
            inboxFile: appSupport.appendingPathComponent("inbox.json"),
            settingsFile: appSupport.appendingPathComponent("settings.json"),
            runDirectory: appSupport.appendingPathComponent("run", isDirectory: true),
            tempDirectory: appSupport.appendingPathComponent("temp", isDirectory: true),
            worktreesDirectory: appSupport.appendingPathComponent("worktrees", isDirectory: true)
        )
        try paths.ensureDirectories()
        return paths
    }

    private func makeTempRoot(prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitForSocket(path: String, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("Socket was not created in time: \(path)")
    }

    private func sendIPCRequest(socketPath: String, request: IPCRequest) throws -> IPCResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "IPC", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < maxPathLength else {
            throw NSError(domain: "IPC", code: 2, userInfo: [NSLocalizedDescriptionKey: "Socket path too long"])
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            raw.initialize(repeating: 0, count: maxPathLength)
            for index in bytes.indices {
                raw[index] = CChar(bitPattern: bytes[index])
            }
        }

        let len = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, len)
            }
        }
        guard connectResult == 0 else {
            throw NSError(domain: "IPC", code: 3, userInfo: [NSLocalizedDescriptionKey: "connect() failed"])
        }

        let requestData = try JSONEncoder().encode(request)
        _ = requestData.withUnsafeBytes { bytes in
            write(fd, bytes.baseAddress, bytes.count)
        }
        shutdown(fd, SHUT_WR)

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                responseData.append(contentsOf: buffer.prefix(Int(count)))
            } else {
                break
            }
        }

        return try JSONDecoder().decode(IPCResponse.self, from: responseData)
    }

    private func makeGitRepo(root: URL, name: String) throws -> URL {
        let repo = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        _ = try runGit(["init", "-q"], currentDirectory: repo.path)
        _ = try runGit(["config", "user.email", "idx0-tests@example.com"], currentDirectory: repo.path)
        _ = try runGit(["config", "user.name", "idx0 tests"], currentDirectory: repo.path)

        let readme = repo.appendingPathComponent("README.md")
        try "integration test\n".data(using: .utf8)?.write(to: readme)

        _ = try runGit(["add", "README.md"], currentDirectory: repo.path)
        _ = try runGit(["commit", "-q", "-m", "initial"], currentDirectory: repo.path)
        return repo
    }

    private func currentBranch(at repoPath: String) throws -> String? {
        let branch = try runGit(["branch", "--show-current"], currentDirectory: repoPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    private func canonicalPath(_ path: String?) -> String? {
        guard let path else { return nil }
        return URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    @discardableResult
    private func runGit(_ arguments: [String], currentDirectory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stdoutString = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderrString = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "SessionServiceIntegrationTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: stderrString.isEmpty ? stdoutString : stderrString]
            )
        }

        return stdoutString
    }
}
