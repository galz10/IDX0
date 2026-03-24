import AppKit
import Darwin
import Foundation
import WebKit

struct ExcalidrawBuildManifest: Codable, Equatable {
    static let canonicalRepositoryURL = "https://github.com/excalidraw/excalidraw.git"
    static let canonicalInstallCommand = "yarn install --frozen-lockfile"
    static let canonicalBuildCommand = "yarn --cwd excalidraw-app build"
    static let canonicalEntrypoint = "excalidraw-app/build/index.html"

    let repositoryURL: String
    let pinnedCommit: String
    let installCommand: String
    let buildCommand: String
    let entrypoint: String
    let requiredArtifacts: [String]

    static let `default` = ExcalidrawBuildManifest(
        repositoryURL: canonicalRepositoryURL,
        pinnedCommit: "d6f0f34fe91a7fab25106f2b31b074c132815d36",
        installCommand: canonicalInstallCommand,
        buildCommand: canonicalBuildCommand,
        entrypoint: canonicalEntrypoint,
        requiredArtifacts: [
            canonicalEntrypoint
        ]
    )

    static func loadFromBundle(_ bundle: Bundle = .main) -> ExcalidrawBuildManifest {
        guard let url = bundle.url(forResource: "excalidraw-build-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ExcalidrawBuildManifest.self, from: data)
        else {
            return .default
        }
        return decoded
    }
}

struct ExcalidrawRuntimePaths {
    let rootDirectory: URL
    let sourceDirectory: URL
    let buildRecordPath: URL
    let buildLogPath: URL
    let buildLockPath: URL
    let originsRecordPath: URL
    let sessionsDirectory: URL
    let sessionDirectory: URL
    let runtimeLogPath: URL

    init(
        sessionID: UUID,
        rootDirectoryOverride: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let idx0Root: URL
        if let rootDirectoryOverride {
            idx0Root = rootDirectoryOverride
        } else {
            let appSupportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            idx0Root = appSupportRoot
                .appendingPathComponent("idx0", isDirectory: true)
                .appendingPathComponent("excalidraw", isDirectory: true)
        }

        rootDirectory = idx0Root
        sourceDirectory = idx0Root.appendingPathComponent("source", isDirectory: true)
        buildRecordPath = idx0Root.appendingPathComponent("manifest.json", isDirectory: false)
        buildLogPath = idx0Root
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("build.log", isDirectory: false)
        buildLockPath = idx0Root.appendingPathComponent("build.lock", isDirectory: false)
        originsRecordPath = idx0Root.appendingPathComponent("session-origins.json", isDirectory: false)
        sessionsDirectory = idx0Root.appendingPathComponent("sessions", isDirectory: true)
        sessionDirectory = sessionsDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        runtimeLogPath = sessionDirectory.appendingPathComponent("runtime.log", isDirectory: false)
    }

    func ensureBaseDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sourceDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: buildLogPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    }

    func removeSessionArtifacts(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: sessionDirectory)
    }
}

enum ExcalidrawTileRuntimeState: Equatable {
    case idle
    case preparingSource
    case building
    case starting
    case live(urlString: String)
    case failed(message: String, logPath: String?)

    var displayMessage: String {
        switch self {
        case .idle:
            return "Ready"
        case .preparingSource:
            return "Preparing Excalidraw source..."
        case .building:
            return "Building Excalidraw..."
        case .starting:
            return "Starting Excalidraw..."
        case .live:
            return "Live"
        case .failed(let message, _):
            return message
        }
    }
}

enum ExcalidrawRuntimeError: LocalizedError {
    case missingTool(String)
    case commandFailed(command: String, code: Int32, stderr: String?)
    case missingArtifact(String)
    case startupTimeout
    case processExitedBeforeReady
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingTool(let tool):
            return "Missing required tool: \(tool)"
        case .commandFailed(let command, let code, let stderr):
            if let stderr, !stderr.isEmpty {
                return "Command failed (\(code)): \(command)\n\(stderr)"
            }
            return "Command failed (\(code)): \(command)"
        case .missingArtifact(let artifact):
            return "Build artifact missing: \(artifact)"
        case .startupTimeout:
            return "Excalidraw did not become ready in time."
        case .processExitedBeforeReady:
            return "Excalidraw process exited before it became ready."
        case .cancelled:
            return "Operation cancelled."
        }
    }
}

private struct ExcalidrawBuildRecord: Codable {
    let pinnedCommit: String
    let entrypoint: String
    let builtAt: Date
}

@MainActor
final class ExcalidrawBuildCoordinator {
    private let processRunner: any ProcessRunnerProtocol
    private let fileManager: FileManager
    private var buildTask: Task<URL, Error>?

    init(processRunner: any ProcessRunnerProtocol = ProcessRunner(), fileManager: FileManager = .default) {
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    func ensureBuilt(
        manifest: ExcalidrawBuildManifest,
        paths: ExcalidrawRuntimePaths,
        onStateUpdate: ((ExcalidrawTileRuntimeState) -> Void)? = nil
    ) async throws -> URL {
        if let entrypoint = try? reusableEntrypointIfAvailable(manifest: manifest, paths: paths) {
            return entrypoint
        }

        if let existingTask = buildTask {
            return try await existingTask.value
        }

        let task = Task { [weak self] () -> URL in
            guard let self else { throw ExcalidrawRuntimeError.cancelled }
            return try await self.performBuild(manifest: manifest, paths: paths, onStateUpdate: onStateUpdate)
        }

        buildTask = task
        do {
            let url = try await task.value
            buildTask = nil
            return url
        } catch {
            buildTask = nil
            throw error
        }
    }

    private func reusableEntrypointIfAvailable(manifest: ExcalidrawBuildManifest, paths: ExcalidrawRuntimePaths) throws -> URL {
        guard fileManager.fileExists(atPath: paths.buildRecordPath.path) else {
            throw ExcalidrawRuntimeError.missingArtifact(paths.buildRecordPath.path)
        }

        let data = try Data(contentsOf: paths.buildRecordPath)
        let record = try JSONDecoder().decode(ExcalidrawBuildRecord.self, from: data)

        guard record.pinnedCommit == manifest.pinnedCommit else {
            throw ExcalidrawRuntimeError.missingArtifact(manifest.pinnedCommit)
        }

        for artifact in manifest.requiredArtifacts {
            let artifactURL = paths.sourceDirectory.appendingPathComponent(artifact, isDirectory: false)
            guard fileManager.fileExists(atPath: artifactURL.path) else {
                throw ExcalidrawRuntimeError.missingArtifact(artifact)
            }
        }

        let entrypointURL = paths.sourceDirectory.appendingPathComponent(record.entrypoint, isDirectory: false)
        guard fileManager.fileExists(atPath: entrypointURL.path) else {
            throw ExcalidrawRuntimeError.missingArtifact(entrypointURL.path)
        }

        return entrypointURL
    }

    private func performBuild(
        manifest: ExcalidrawBuildManifest,
        paths: ExcalidrawRuntimePaths,
        onStateUpdate: ((ExcalidrawTileRuntimeState) -> Void)?
    ) async throws -> URL {
        try paths.ensureBaseDirectories(fileManager: fileManager)

        onStateUpdate?(.preparingSource)
        appendBuildLog(paths: paths, line: "== build start \(Date())")

        try "pid=\(ProcessInfo.processInfo.processIdentifier)\n".write(
            to: paths.buildLockPath,
            atomically: true,
            encoding: .utf8
        )
        defer { try? fileManager.removeItem(at: paths.buildLockPath) }

        let resolvedGitPath = try await ensureToolAvailable("git", paths: paths)
        let resolvedNodePath = try await ensureToolAvailable("node", paths: paths)
        let resolvedYarnPath = try await ensureToolAvailable("yarn", paths: paths)
        let preferredToolDirectories = uniqueParentDirectories(for: [resolvedGitPath, resolvedNodePath, resolvedYarnPath])

        if fileManager.fileExists(atPath: paths.sourceDirectory.appendingPathComponent(".git", isDirectory: true).path) {
            appendBuildLog(paths: paths, line: "Refreshing existing repository")
            try await runChecked(
                executable: resolvedGitPath,
                arguments: ["-C", paths.sourceDirectory.path, "fetch", "--all", "--tags"],
                currentDirectory: paths.sourceDirectory.path,
                paths: paths
            )
        } else {
            appendBuildLog(paths: paths, line: "Cloning repository")
            try await runChecked(
                executable: resolvedGitPath,
                arguments: ["clone", manifest.repositoryURL, paths.sourceDirectory.path],
                currentDirectory: paths.rootDirectory.path,
                paths: paths
            )
        }

        try await runChecked(
            executable: resolvedGitPath,
            arguments: ["-C", paths.sourceDirectory.path, "checkout", manifest.pinnedCommit],
            currentDirectory: paths.sourceDirectory.path,
            paths: paths
        )

        onStateUpdate?(.building)

        let installCommand = nonInteractiveShellCommand(
            manifest.installCommand,
            preferredToolDirectories: preferredToolDirectories
        )
        try await runChecked(
            executable: "/bin/zsh",
            arguments: ["-lc", installCommand],
            currentDirectory: paths.sourceDirectory.path,
            paths: paths
        )

        let buildCommand = nonInteractiveShellCommand(
            manifest.buildCommand,
            preferredToolDirectories: preferredToolDirectories
        )
        try await runChecked(
            executable: "/bin/zsh",
            arguments: ["-lc", buildCommand],
            currentDirectory: paths.sourceDirectory.path,
            paths: paths
        )

        if let firstMissingArtifact = missingRequiredArtifacts(manifest: manifest, paths: paths).first {
            throw ExcalidrawRuntimeError.missingArtifact(firstMissingArtifact)
        }

        let record = ExcalidrawBuildRecord(
            pinnedCommit: manifest.pinnedCommit,
            entrypoint: manifest.entrypoint,
            builtAt: Date()
        )
        let recordData = try JSONEncoder().encode(record)
        try fileManager.createDirectory(at: paths.buildRecordPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try recordData.write(to: paths.buildRecordPath, options: .atomic)

        appendBuildLog(paths: paths, line: "== build complete \(Date())")

        let entrypointURL = paths.sourceDirectory.appendingPathComponent(manifest.entrypoint, isDirectory: false)
        guard fileManager.fileExists(atPath: entrypointURL.path) else {
            throw ExcalidrawRuntimeError.missingArtifact(manifest.entrypoint)
        }

        return entrypointURL
    }

    private func ensureToolAvailable(_ tool: String, paths: ExcalidrawRuntimePaths) async throws -> String {
        let probes: [(executable: String, arguments: [String], display: String)] = [
            ("/usr/bin/which", [tool], "which \(tool)"),
            ("/bin/zsh", ["-lc", "whence -p \(tool)"], "zsh -lc 'whence -p \(tool)'"),
            ("/bin/zsh", ["-ilc", "whence -p \(tool)"], "zsh -ilc 'whence -p \(tool)'")
        ]

        for probe in probes {
            let result = try await processRunner.run(
                executable: probe.executable,
                arguments: probe.arguments,
                currentDirectory: nil
            )

            appendBuildLog(paths: paths, line: "$ \(probe.display)")
            if !result.stdout.isEmpty {
                appendBuildLog(paths: paths, line: result.stdout)
            }
            if !result.stderr.isEmpty {
                appendBuildLog(paths: paths, line: result.stderr)
            }

            if result.exitCode == 0,
               let resolvedPath = firstExecutablePath(from: result.stdout) {
                appendBuildLog(paths: paths, line: "Resolved \(tool) -> \(resolvedPath)")
                return resolvedPath
            }
        }

        throw ExcalidrawRuntimeError.missingTool(tool)
    }

    private func firstExecutablePath(from output: String) -> String? {
        let candidates = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return candidates.first(where: { $0.hasPrefix("/") })
    }

    private func uniqueParentDirectories(for resolvedToolPaths: [String]) -> [String] {
        var seen: Set<String> = []
        var directories: [String] = []

        for path in resolvedToolPaths {
            let parentDirectory = URL(fileURLWithPath: path).deletingLastPathComponent().path
            guard !parentDirectory.isEmpty, !seen.contains(parentDirectory) else { continue }
            seen.insert(parentDirectory)
            directories.append(parentDirectory)
        }

        return directories
    }

    private func nonInteractiveShellCommand(
        _ command: String,
        preferredToolDirectories: [String]
    ) -> String {
        var parts = [
            "export CI=1",
            "export COREPACK_ENABLE_DOWNLOAD_PROMPT=0"
        ]

        if !preferredToolDirectories.isEmpty {
            let joinedDirectories = preferredToolDirectories.joined(separator: ":")
            parts.append("export PATH='\(shellEscapeSingleQuoted(joinedDirectories))':\"$PATH\"")
        }

        parts.append(command)
        return parts.joined(separator: "; ")
    }

    private func shellEscapeSingleQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }

    private func runChecked(
        executable: String,
        arguments: [String],
        currentDirectory: String?,
        paths: ExcalidrawRuntimePaths
    ) async throws {
        let command = ([executable] + arguments).joined(separator: " ")
        appendBuildLog(paths: paths, line: "$ \(command)")

        let result = try await processRunner.run(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory
        )

        if !result.stdout.isEmpty {
            appendBuildLog(paths: paths, line: result.stdout)
        }
        if !result.stderr.isEmpty {
            appendBuildLog(paths: paths, line: result.stderr)
        }

        guard result.exitCode == 0 else {
            throw ExcalidrawRuntimeError.commandFailed(
                command: command,
                code: result.exitCode,
                stderr: result.stderr.isEmpty ? nil : result.stderr
            )
        }
    }

    private func appendBuildLog(paths: ExcalidrawRuntimePaths, line: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logLine = "[\(timestamp)] \(line)\n"

        do {
            try fileManager.createDirectory(at: paths.buildLogPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: paths.buildLogPath.path) {
                try logLine.write(to: paths.buildLogPath, atomically: true, encoding: .utf8)
                return
            }

            let handle = try FileHandle(forWritingTo: paths.buildLogPath)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = logLine.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } catch {
            Logger.error("Failed to append Excalidraw build log: \(error.localizedDescription)")
        }
    }

    private func missingRequiredArtifacts(manifest: ExcalidrawBuildManifest, paths: ExcalidrawRuntimePaths) -> [String] {
        manifest.requiredArtifacts.filter { artifact in
            let artifactURL = paths.sourceDirectory.appendingPathComponent(artifact, isDirectory: false)
            return !fileManager.fileExists(atPath: artifactURL.path)
        }
    }
}

private struct ExcalidrawSessionOriginRecord: Codable {
    var portsBySessionID: [String: Int] = [:]
}

@MainActor
final class ExcalidrawSessionOriginStore {
    private let recordURL: URL
    private let fileManager: FileManager
    private let portBase: Int
    private let portSpan: Int

    init(
        recordURL: URL,
        fileManager: FileManager = .default,
        portBase: Int = 46_000,
        portSpan: Int = 10_000
    ) {
        self.recordURL = recordURL
        self.fileManager = fileManager
        self.portBase = portBase
        self.portSpan = max(256, portSpan)
    }

    func preferredPort(for sessionID: UUID) -> Int {
        let record = loadRecord()
        if let existing = record.portsBySessionID[sessionID.uuidString], isValidPort(existing) {
            return existing
        }
        return deterministicPort(for: sessionID)
    }

    func persistPort(_ port: Int, for sessionID: UUID) {
        guard isValidPort(port) else { return }
        var record = loadRecord()
        record.portsBySessionID[sessionID.uuidString] = port
        saveRecord(record)
    }

    func removePort(for sessionID: UUID) {
        var record = loadRecord()
        record.portsBySessionID.removeValue(forKey: sessionID.uuidString)
        saveRecord(record)
    }

    private func loadRecord() -> ExcalidrawSessionOriginRecord {
        guard fileManager.fileExists(atPath: recordURL.path),
              let data = try? Data(contentsOf: recordURL),
              let decoded = try? JSONDecoder().decode(ExcalidrawSessionOriginRecord.self, from: data)
        else {
            return ExcalidrawSessionOriginRecord()
        }
        return decoded
    }

    private func saveRecord(_ record: ExcalidrawSessionOriginRecord) {
        do {
            try fileManager.createDirectory(at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(record)
            try data.write(to: recordURL, options: .atomic)
        } catch {
            Logger.error("Failed to persist Excalidraw session origin record: \(error.localizedDescription)")
        }
    }

    private func deterministicPort(for sessionID: UUID) -> Int {
        let hash = fnv1a64(sessionID.uuidString)
        return portBase + Int(hash % UInt64(portSpan))
    }

    private func fnv1a64(_ value: String) -> UInt64 {
        let prime: UInt64 = 1_099_511_628_211
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return hash
    }

    private func isValidPort(_ port: Int) -> Bool {
        (1025...65535).contains(port)
    }
}

@MainActor
final class ExcalidrawTileController: ObservableObject, NiriAppTileRuntimeControlling {
    @Published private(set) var state: ExcalidrawTileRuntimeState = .idle

    let sessionID: UUID
    let itemID: UUID
    let webView: WKWebView

    private let launchDirectoryProvider: () -> String?
    private let buildCoordinator: ExcalidrawBuildCoordinator
    private let originStore: ExcalidrawSessionOriginStore
    private let manifestProvider: () -> ExcalidrawBuildManifest
    private let paths: ExcalidrawRuntimePaths

    private let readinessIntervalNanoseconds: UInt64 = 250_000_000
    private let readinessTimeoutSeconds: TimeInterval = 20
    private let maxAutomaticRestarts = 3
    private let defaultZoom: CGFloat = 1.0
    private let minimumZoom: CGFloat = 0.5
    private let maximumZoom: CGFloat = 3.0

    private var startTask: Task<Void, Never>?
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var logHandle: FileHandle?
    private var userStopped = false
    private var automaticRestartCount = 0

    init(
        sessionID: UUID,
        itemID: UUID,
        launchDirectoryProvider: @escaping () -> String?,
        buildCoordinator: ExcalidrawBuildCoordinator,
        originStore: ExcalidrawSessionOriginStore? = nil,
        manifestProvider: @escaping () -> ExcalidrawBuildManifest = { ExcalidrawBuildManifest.loadFromBundle() },
        rootDirectoryOverride: URL? = nil
    ) {
        self.sessionID = sessionID
        self.itemID = itemID
        self.launchDirectoryProvider = launchDirectoryProvider
        self.buildCoordinator = buildCoordinator
        self.paths = ExcalidrawRuntimePaths(sessionID: sessionID, rootDirectoryOverride: rootDirectoryOverride)
        self.originStore = originStore ?? ExcalidrawSessionOriginStore(recordURL: paths.originsRecordPath)
        self.manifestProvider = manifestProvider

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.pageZoom = defaultZoom
    }

    func ensureStarted() {
        guard startTask == nil else { return }
        switch state {
        case .preparingSource, .building, .starting, .live:
            return
        case .idle, .failed:
            break
        }

        userStopped = false
        startTask = Task { [weak self] in
            guard let self else { return }
            await self.runStartupSequence()
            self.startTask = nil
        }
    }

    func retry() {
        stop()
        automaticRestartCount = 0
        state = .idle
        ensureStarted()
    }

    func stop() {
        userStopped = true
        startTask?.cancel()
        startTask = nil
        terminateProcess()
        state = .idle
    }

    func openLogsInFinder() {
        let url: URL
        if case .failed(_, let logPath) = state,
           let logPath,
           !logPath.isEmpty {
            url = URL(fileURLWithPath: logPath, isDirectory: false)
        } else {
            url = paths.runtimeLogPath
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    var runtimeLogPath: String {
        paths.runtimeLogPath.path
    }

    @discardableResult
    func adjustZoom(by delta: CGFloat) -> Bool {
        let current = webView.pageZoom
        let next = max(minimumZoom, min(maximumZoom, current + delta))
        webView.pageZoom = next
        return true
    }

    private func runStartupSequence() async {
        let manifest = manifestProvider()

        while !Task.isCancelled {
            do {
                try await startupAttempt(manifest: manifest)
                automaticRestartCount = 0
                return
            } catch {
                if userStopped || Task.isCancelled {
                    return
                }

                let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                appendRuntimeLog("startup attempt failed: \(description)")

                if !isRetryableStartupError(error) {
                    state = .failed(message: description, logPath: logPathForError(error))
                    return
                }

                guard automaticRestartCount < maxAutomaticRestarts else {
                    state = .failed(message: description, logPath: logPathForError(error))
                    return
                }

                automaticRestartCount += 1
                let backoff = min(pow(2, Double(automaticRestartCount - 1)) * 0.5, 10)
                state = .starting
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
        }
    }

    private func startupAttempt(manifest: ExcalidrawBuildManifest) async throws {
        try paths.ensureBaseDirectories()

        let entrypointURL = try await buildCoordinator.ensureBuilt(manifest: manifest, paths: paths) { [weak self] newState in
            self?.state = newState
        }

        if userStopped || Task.isCancelled {
            throw ExcalidrawRuntimeError.cancelled
        }

        let preferredPort = originStore.preferredPort(for: sessionID)
        let port = try reserveLoopbackPort(preferredPort: preferredPort)
        originStore.persistPort(port, for: sessionID)

        state = .starting

        let webRootURL = entrypointURL.deletingLastPathComponent()
        try launchProcess(
            webRootURL: webRootURL,
            port: port,
            launchDirectory: launchDirectoryProvider() ?? FileManager.default.homeDirectoryForCurrentUser.path
        )

        let ready = await waitForServerReady(port: port)
        guard ready else {
            let exitedBeforeReady = (process?.isRunning == false)
            terminateProcess()
            if userStopped || Task.isCancelled {
                throw ExcalidrawRuntimeError.cancelled
            }
            if exitedBeforeReady {
                throw ExcalidrawRuntimeError.processExitedBeforeReady
            }
            throw ExcalidrawRuntimeError.startupTimeout
        }

        if userStopped || Task.isCancelled {
            terminateProcess()
            throw ExcalidrawRuntimeError.cancelled
        }

        let url = URL(string: "http://127.0.0.1:\(port)/")!
        webView.load(URLRequest(url: url))
        state = .live(urlString: url.absoluteString)
        appendRuntimeLog("runtime live at \(url.absoluteString)")
    }

    private func reserveLoopbackPort(preferredPort: Int) throws -> Int {
        if let reserved = try reserveSpecificLoopbackPort(preferredPort) {
            return reserved
        }

        for offset in 1...32 {
            if let candidate = try reserveSpecificLoopbackPort(preferredPort + offset) {
                return candidate
            }
            if let candidate = try reserveSpecificLoopbackPort(preferredPort - offset) {
                return candidate
            }
        }

        if let fallback = try reserveSpecificLoopbackPort(0) {
            return fallback
        }

        throw ExcalidrawRuntimeError.startupTimeout
    }

    private func reserveSpecificLoopbackPort(_ requestedPort: Int) throws -> Int? {
        guard requestedPort == 0 || (1025...65535).contains(requestedPort) else {
            return nil
        }

        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return nil }
        defer { close(socketFD) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(requestedPort).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            return nil
        }

        var assignedAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)

        let nameResult = withUnsafeMutablePointer(to: &assignedAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }

        guard nameResult == 0 else {
            throw ExcalidrawRuntimeError.startupTimeout
        }

        return Int(UInt16(bigEndian: assignedAddress.sin_port))
    }

    private func launchProcess(
        webRootURL: URL,
        port: Int,
        launchDirectory: String
    ) throws {
        terminateProcess()

        try FileManager.default.createDirectory(at: paths.runtimeLogPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: paths.runtimeLogPath.path) {
            FileManager.default.createFile(atPath: paths.runtimeLogPath.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: paths.runtimeLogPath)
        try handle.seekToEnd()
        logHandle = handle

        let process = Process()

        if let pythonPath = resolveRuntimeExecutablePath("python3") {
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1"]
            appendRuntimeLog("resolved python executable: \(pythonPath)")
        } else if FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1"]
            appendRuntimeLog("python resolution fallback: using /usr/bin/python3")
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-m", "http.server", String(port), "--bind", "127.0.0.1"]
            appendRuntimeLog("python resolution fallback: using /usr/bin/env python3")
        }

        process.currentDirectoryURL = webRootURL

        var env = ProcessInfo.processInfo.environment
        env["PWD"] = launchDirectory
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.appendLogData(data)
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.appendLogData(data)
            }
        }

        process.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in
                self?.handleProcessExit(terminated)
            }
        }

        try process.run()

        self.process = process
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        appendRuntimeLog("spawned process pid=\(process.processIdentifier) port=\(port)")
    }

    private func resolveRuntimeExecutablePath(_ executable: String) -> String? {
        guard executable.range(of: #"^[A-Za-z0-9._+-]+$"#, options: .regularExpression) != nil else {
            return nil
        }

        let probes: [(String, [String])] = [
            ("/usr/bin/which", [executable]),
            ("/bin/zsh", ["-lc", "whence -p \(executable)"]),
            ("/bin/zsh", ["-ilc", "whence -p \(executable)"])
        ]

        for probe in probes {
            if let resolved = runRuntimeProbe(executable: probe.0, arguments: probe.1) {
                return resolved
            }
        }

        return nil
    }

    private func runRuntimeProbe(executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let candidates = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.hasPrefix("/") }

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        return nil
    }

    private func waitForServerReady(port: Int) async -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        let deadline = Date().addingTimeInterval(readinessTimeoutSeconds)

        while Date() < deadline {
            if Task.isCancelled || userStopped {
                return false
            }

            if process?.isRunning == false {
                return false
            }

            if await probeServer(url: url) {
                return true
            }

            try? await Task.sleep(nanoseconds: readinessIntervalNanoseconds)
        }

        return false
    }

    private func probeServer(url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }

    private func handleProcessExit(_ terminatedProcess: Process) {
        appendRuntimeLog(
            "process exited status=\(terminatedProcess.terminationStatus) reason=\(terminatedProcess.terminationReason.rawValue)"
        )

        terminateProcess()

        guard !userStopped else { return }

        if case .failed = state {
            return
        }

        if startTask == nil {
            state = .starting
            startTask = Task { [weak self] in
                guard let self else { return }
                await self.runStartupSequence()
                self.startTask = nil
            }
        }
    }

    private func terminateProcess() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil

        if let process, process.isRunning {
            process.terminate()
        }
        self.process = nil

        if let handle = logHandle {
            try? handle.close()
        }
        logHandle = nil
    }

    private func appendLogData(_ data: Data) {
        guard let logHandle else { return }
        do {
            try logHandle.seekToEnd()
            try logHandle.write(contentsOf: data)
        } catch {
            Logger.error("Failed writing Excalidraw runtime log data: \(error.localizedDescription)")
        }
    }

    private func appendRuntimeLog(_ line: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "[\(timestamp)] \(line)\n".data(using: .utf8) else { return }

        if logHandle == nil {
            do {
                try FileManager.default.createDirectory(at: paths.runtimeLogPath.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: paths.runtimeLogPath.path) {
                    FileManager.default.createFile(atPath: paths.runtimeLogPath.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: paths.runtimeLogPath)
                try handle.seekToEnd()
                logHandle = handle
            } catch {
                Logger.error("Failed opening Excalidraw runtime log: \(error.localizedDescription)")
                return
            }
        }

        appendLogData(data)
    }

    private func isRetryableStartupError(_ error: Error) -> Bool {
        guard let runtimeError = error as? ExcalidrawRuntimeError else {
            return false
        }
        switch runtimeError {
        case .startupTimeout, .processExitedBeforeReady:
            return true
        case .missingTool, .commandFailed, .missingArtifact, .cancelled:
            return false
        }
    }

    private func logPathForError(_ error: Error) -> String {
        guard let runtimeError = error as? ExcalidrawRuntimeError else {
            return paths.runtimeLogPath.path
        }
        switch runtimeError {
        case .missingTool, .commandFailed, .missingArtifact:
            return paths.buildLogPath.path
        case .startupTimeout, .processExitedBeforeReady, .cancelled:
            return paths.runtimeLogPath.path
        }
    }
}
