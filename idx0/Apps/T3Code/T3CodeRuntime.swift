import AppKit
import Darwin
import Foundation
import WebKit

struct T3BuildManifest: Codable, Equatable {
    static let canonicalRepositoryURL = "https://github.com/pingdotgg/t3code.git"
    static let canonicalBuildCommand = "bun run --cwd apps/web build && bun run --cwd apps/server build"
    static let canonicalEntrypoint = "apps/server/dist/index.mjs"
    static let canonicalClientArtifact = "apps/server/dist/client/index.html"

    let repositoryURL: String
    let pinnedCommit: String
    let installCommand: String
    let buildCommand: String
    let entrypoint: String
    let requiredArtifacts: [String]

    static let `default` = T3BuildManifest(
        repositoryURL: canonicalRepositoryURL,
        pinnedCommit: "2a237c20019a",
        installCommand: "bun install --frozen-lockfile",
        buildCommand: canonicalBuildCommand,
        entrypoint: canonicalEntrypoint,
        requiredArtifacts: [
            canonicalEntrypoint,
            canonicalClientArtifact
        ]
    )

    static func loadFromBundle(_ bundle: Bundle = .main) -> T3BuildManifest {
        guard let url = bundle.url(forResource: "t3-build-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(T3BuildManifest.self, from: data)
        else {
            return .default
        }
        return decoded.normalized()
    }

    func normalized() -> T3BuildManifest {
        var normalizedRepositoryURL = repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedRepositoryURL.contains("t3dotgg/t3.chat") {
            normalizedRepositoryURL = Self.canonicalRepositoryURL
        }

        var normalizedBuildCommand = buildCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedBuildCommand == "bun run --cwd apps/server build" {
            normalizedBuildCommand = Self.canonicalBuildCommand
        }

        var normalizedEntrypoint = entrypoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedEntrypoint == "apps/server/dist/index.cjs" {
            normalizedEntrypoint = Self.canonicalEntrypoint
        }

        let oldEntrypoint = "apps/server/dist/index.cjs"
        var normalizedRequiredArtifacts = requiredArtifacts.map { artifact in
            let trimmed = artifact.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == oldEntrypoint ? Self.canonicalEntrypoint : trimmed
        }

        if !normalizedRequiredArtifacts.contains(Self.canonicalEntrypoint) {
            normalizedRequiredArtifacts.insert(Self.canonicalEntrypoint, at: 0)
        }

        if !normalizedRequiredArtifacts.contains(Self.canonicalClientArtifact) {
            normalizedRequiredArtifacts.append(Self.canonicalClientArtifact)
        }

        if normalizedRepositoryURL == repositoryURL &&
            normalizedBuildCommand == buildCommand &&
            normalizedEntrypoint == entrypoint &&
            normalizedRequiredArtifacts == requiredArtifacts {
            return self
        }

        return T3BuildManifest(
            repositoryURL: normalizedRepositoryURL,
            pinnedCommit: pinnedCommit,
            installCommand: installCommand,
            buildCommand: normalizedBuildCommand,
            entrypoint: normalizedEntrypoint,
            requiredArtifacts: normalizedRequiredArtifacts
        )
    }
}

struct T3RuntimePaths {
    let rootDirectory: URL
    let sourceDirectory: URL
    let buildRecordPath: URL
    let buildLogPath: URL
    let buildLockPath: URL
    let sessionsDirectory: URL
    let sessionDirectory: URL
    let sessionStateDirectory: URL
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
                .appendingPathComponent("t3code", isDirectory: true)
        }

        rootDirectory = idx0Root
        sourceDirectory = idx0Root.appendingPathComponent("source", isDirectory: true)
        buildRecordPath = idx0Root.appendingPathComponent("manifest.json", isDirectory: false)
        buildLogPath = idx0Root.appendingPathComponent("logs", isDirectory: true).appendingPathComponent("build.log", isDirectory: false)
        buildLockPath = idx0Root.appendingPathComponent("build.lock", isDirectory: false)
        sessionsDirectory = idx0Root.appendingPathComponent("sessions", isDirectory: true)
        sessionDirectory = sessionsDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        sessionStateDirectory = sessionDirectory.appendingPathComponent("state", isDirectory: true)
        runtimeLogPath = sessionDirectory.appendingPathComponent("runtime.log", isDirectory: false)
    }

    func ensureBaseDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sourceDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: buildLogPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    }
}

enum T3TileRuntimeState: Equatable {
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
            return "Preparing T3 Code source..."
        case .building:
            return "Building T3 Code..."
        case .starting:
            return "Starting T3 Code..."
        case .live:
            return "Live"
        case .failed(let message, _):
            return message
        }
    }
}

enum T3RuntimeError: LocalizedError {
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
            return "T3 Code did not become ready in time."
        case .processExitedBeforeReady:
            return "T3 Code process exited before it became ready."
        case .cancelled:
            return "Operation cancelled."
        }
    }
}

private struct T3BuildRecord: Codable {
    let pinnedCommit: String
    let entrypoint: String
    let builtAt: Date
}

@MainActor
final class T3BuildCoordinator {
    private let processRunner: ProcessRunnerProtocol
    private let fileManager: FileManager
    private var buildTask: Task<URL, Error>?

    init(processRunner: ProcessRunnerProtocol = ProcessRunner(), fileManager: FileManager = .default) {
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    func ensureBuilt(
        manifest: T3BuildManifest,
        paths: T3RuntimePaths,
        onStateUpdate: ((T3TileRuntimeState) -> Void)? = nil
    ) async throws -> URL {
        if let entrypoint = try? reusableEntrypointIfAvailable(manifest: manifest, paths: paths) {
            return entrypoint
        }

        if let existingTask = buildTask {
            return try await existingTask.value
        }

        let task = Task { [weak self] () -> URL in
            guard let self else { throw T3RuntimeError.cancelled }
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

    private func reusableEntrypointIfAvailable(manifest: T3BuildManifest, paths: T3RuntimePaths) throws -> URL {
        guard fileManager.fileExists(atPath: paths.buildRecordPath.path) else {
            throw T3RuntimeError.missingArtifact(paths.buildRecordPath.path)
        }

        let data = try Data(contentsOf: paths.buildRecordPath)
        let record = try JSONDecoder().decode(T3BuildRecord.self, from: data)

        guard record.pinnedCommit == manifest.pinnedCommit else {
            throw T3RuntimeError.missingArtifact(manifest.pinnedCommit)
        }

        for artifact in manifest.requiredArtifacts {
            let artifactURL = paths.sourceDirectory.appendingPathComponent(artifact, isDirectory: false)
            guard fileManager.fileExists(atPath: artifactURL.path) else {
                throw T3RuntimeError.missingArtifact(artifact)
            }
        }

        let entrypointURL = paths.sourceDirectory.appendingPathComponent(record.entrypoint, isDirectory: false)
        guard fileManager.fileExists(atPath: entrypointURL.path) else {
            throw T3RuntimeError.missingArtifact(entrypointURL.path)
        }

        return entrypointURL
    }

    private func performBuild(
        manifest: T3BuildManifest,
        paths: T3RuntimePaths,
        onStateUpdate: ((T3TileRuntimeState) -> Void)?
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

        try await ensureToolAvailable("git", paths: paths)
        try await ensureToolAvailable("node", paths: paths)
        try await ensureToolAvailable("bun", paths: paths)

        if fileManager.fileExists(atPath: paths.sourceDirectory.appendingPathComponent(".git", isDirectory: true).path) {
            appendBuildLog(paths: paths, line: "Refreshing existing repository")
            try await runChecked(
                executable: "/usr/bin/git",
                arguments: ["-C", paths.sourceDirectory.path, "fetch", "--all", "--tags"],
                currentDirectory: paths.sourceDirectory.path,
                paths: paths
            )
        } else {
            appendBuildLog(paths: paths, line: "Cloning repository")
            try await runChecked(
                executable: "/usr/bin/git",
                arguments: ["clone", manifest.repositoryURL, paths.sourceDirectory.path],
                currentDirectory: paths.rootDirectory.path,
                paths: paths
            )
        }

        try await runChecked(
            executable: "/usr/bin/git",
            arguments: ["-C", paths.sourceDirectory.path, "checkout", manifest.pinnedCommit],
            currentDirectory: paths.sourceDirectory.path,
            paths: paths
        )

        onStateUpdate?(.building)

        try await runChecked(
            executable: "/bin/zsh",
            arguments: ["-ilc", manifest.installCommand],
            currentDirectory: paths.sourceDirectory.path,
            paths: paths
        )

        try await runChecked(
            executable: "/bin/zsh",
            arguments: ["-ilc", manifest.buildCommand],
            currentDirectory: paths.sourceDirectory.path,
            paths: paths
        )

        var missingArtifacts = missingRequiredArtifacts(manifest: manifest, paths: paths)
        if !missingArtifacts.isEmpty {
            // Older manifests only built the server. If client artifacts are missing,
            // run a canonical full build (web + server) before failing.
            let needsClientBundle = missingArtifacts.contains("apps/server/dist/client/index.html")
            if needsClientBundle {
                appendBuildLog(paths: paths, line: "Client bundle missing after build; running canonical full build")
                try await runChecked(
                    executable: "/bin/zsh",
                    arguments: ["-ilc", T3BuildManifest.canonicalBuildCommand],
                    currentDirectory: paths.sourceDirectory.path,
                    paths: paths
                )
                missingArtifacts = missingRequiredArtifacts(manifest: manifest, paths: paths)
            }
        }

        if let firstMissingArtifact = missingArtifacts.first {
            throw T3RuntimeError.missingArtifact(firstMissingArtifact)
        }

        let record = T3BuildRecord(
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
            throw T3RuntimeError.missingArtifact(manifest.entrypoint)
        }

        return entrypointURL
    }

    private func ensureToolAvailable(_ tool: String, paths: T3RuntimePaths) async throws {
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
                return
            }
        }

        throw T3RuntimeError.missingTool(tool)
    }

    private func firstExecutablePath(from output: String) -> String? {
        let candidates = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return candidates.first(where: { $0.hasPrefix("/") })
    }

    private func runChecked(
        executable: String,
        arguments: [String],
        currentDirectory: String?,
        paths: T3RuntimePaths
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
            throw T3RuntimeError.commandFailed(
                command: command,
                code: result.exitCode,
                stderr: result.stderr.isEmpty ? nil : result.stderr
            )
        }
    }

    private func appendBuildLog(paths: T3RuntimePaths, line: String) {
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
            Logger.error("Failed to append T3 build log: \(error.localizedDescription)")
        }
    }

    private func missingRequiredArtifacts(manifest: T3BuildManifest, paths: T3RuntimePaths) -> [String] {
        manifest.requiredArtifacts.filter { artifact in
            let artifactURL = paths.sourceDirectory.appendingPathComponent(artifact, isDirectory: false)
            return !fileManager.fileExists(atPath: artifactURL.path)
        }
    }
}

@MainActor
final class T3StateSnapshotManager {
    private let fileManager: FileManager
    private let skippedSnapshotEntries: Set<String> = [
        "logs",
        "state.sqlite-shm",
        "state.sqlite-wal"
    ]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func prepareSessionSnapshot(paths: T3RuntimePaths) throws -> URL {
        try paths.ensureBaseDirectories(fileManager: fileManager)

        if fileManager.fileExists(atPath: paths.sessionStateDirectory.path) {
            pruneTransientSnapshotArtifacts(in: paths.sessionStateDirectory)
            return paths.sessionStateDirectory
        }

        let baseStatePath = NSString(string: "~/.t3/userdata").expandingTildeInPath
        let baseStateURL = URL(fileURLWithPath: baseStatePath, isDirectory: true)

        if fileManager.fileExists(atPath: baseStateURL.path) {
            try copyDirectoryContents(from: baseStateURL, to: paths.sessionStateDirectory)
        } else {
            try fileManager.createDirectory(at: paths.sessionStateDirectory, withIntermediateDirectories: true)
        }

        pruneTransientSnapshotArtifacts(in: paths.sessionStateDirectory)

        return paths.sessionStateDirectory
    }

    func removeSessionSnapshot(paths: T3RuntimePaths) {
        try? fileManager.removeItem(at: paths.sessionDirectory)
    }

    private func copyDirectoryContents(from source: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let contents = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: []
        )

        for item in contents where !skippedSnapshotEntries.contains(item.lastPathComponent) {
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory)
            let destinationItem = destination.appendingPathComponent(
                item.lastPathComponent,
                isDirectory: isDirectory.boolValue
            )
            try fileManager.copyItem(at: item, to: destinationItem)
        }
    }

    private func pruneTransientSnapshotArtifacts(in stateDirectory: URL) {
        let logsDirectory = stateDirectory.appendingPathComponent("logs", isDirectory: true)
        if fileManager.fileExists(atPath: logsDirectory.path) {
            try? fileManager.removeItem(at: logsDirectory)
        }

        for transientFilename in ["state.sqlite-shm", "state.sqlite-wal"] {
            let transientURL = stateDirectory.appendingPathComponent(transientFilename, isDirectory: false)
            if fileManager.fileExists(atPath: transientURL.path) {
                try? fileManager.removeItem(at: transientURL)
            }
        }
    }
}

@MainActor
final class T3TileController: ObservableObject, NiriAppTileRuntimeControlling {
    @Published private(set) var state: T3TileRuntimeState = .idle

    let sessionID: UUID
    let itemID: UUID
    let webView: WKWebView

    private let launchDirectoryProvider: () -> String?
    private let buildCoordinator: T3BuildCoordinator
    private let snapshotManager: T3StateSnapshotManager
    private let manifestProvider: () -> T3BuildManifest
    private let paths: T3RuntimePaths

    private let readinessIntervalNanoseconds: UInt64 = 250_000_000
    private let readinessTimeoutSeconds: TimeInterval = 20
    private let maxAutomaticRestarts = 3
    private let minimumZoom: CGFloat = 0.5
    private let maximumZoom: CGFloat = 3.0
    private let maxWebContentReloadAttempts = 2

    private var startTask: Task<Void, Never>?
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var logHandle: FileHandle?
    private var webViewDelegate: EmbeddedWebViewDelegate?
    private var webContentTerminationCount = 0
    private var userStopped = false
    private var automaticRestartCount = 0

    init(
        sessionID: UUID,
        itemID: UUID,
        launchDirectoryProvider: @escaping () -> String?,
        buildCoordinator: T3BuildCoordinator,
        snapshotManager: T3StateSnapshotManager,
        manifestProvider: @escaping () -> T3BuildManifest = { T3BuildManifest.loadFromBundle() }
    ) {
        self.sessionID = sessionID
        self.itemID = itemID
        self.launchDirectoryProvider = launchDirectoryProvider
        self.buildCoordinator = buildCoordinator
        self.snapshotManager = snapshotManager
        self.manifestProvider = manifestProvider
        self.paths = T3RuntimePaths(sessionID: sessionID)

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)

        let delegate = EmbeddedWebViewDelegate(logLabel: "T3Code[\(sessionID.uuidString)]") { [weak self] view in
            self?.handleWebContentTermination(view)
        }
        webView.navigationDelegate = delegate
        webViewDelegate = delegate
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
        webContentTerminationCount = 0
        state = .idle
    }

    func openLogsInFinder() {
        let url = paths.runtimeLogPath
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

    private func startupAttempt(manifest: T3BuildManifest) async throws {
        try paths.ensureBaseDirectories()

        let entrypointURL = try await buildCoordinator.ensureBuilt(manifest: manifest, paths: paths) { [weak self] newState in
            self?.state = newState
        }

        if userStopped || Task.isCancelled {
            throw T3RuntimeError.cancelled
        }

        let stateDirectory = try snapshotManager.prepareSessionSnapshot(paths: paths)
        let port = try reserveLoopbackPort()
        let launchEntrypointURL = resolveLaunchEntrypoint(from: entrypointURL)

        state = .starting
        try launchProcess(
            entrypointURL: launchEntrypointURL,
            port: port,
            stateDirectory: stateDirectory,
            workingDirectory: launchDirectoryProvider() ?? FileManager.default.homeDirectoryForCurrentUser.path
        )

        let ready = await waitForServerReady(port: port)
        guard ready else {
            terminateProcess()
            if userStopped || Task.isCancelled {
                throw T3RuntimeError.cancelled
            }
            if process?.isRunning == false {
                throw T3RuntimeError.processExitedBeforeReady
            }
            throw T3RuntimeError.startupTimeout
        }

        if userStopped || Task.isCancelled {
            terminateProcess()
            throw T3RuntimeError.cancelled
        }

        let url = URL(string: "http://127.0.0.1:\(port)")!
        webContentTerminationCount = 0
        webView.load(URLRequest(url: url))
        state = .live(urlString: url.absoluteString)
        appendRuntimeLog("runtime live at \(url.absoluteString)")
    }

    private func resolveLaunchEntrypoint(from entrypointURL: URL) -> URL {
        guard entrypointURL.pathExtension == "cjs" else {
            return entrypointURL
        }

        let mjsEntrypointURL = entrypointURL
            .deletingPathExtension()
            .appendingPathExtension("mjs")

        guard FileManager.default.fileExists(atPath: mjsEntrypointURL.path) else {
            return entrypointURL
        }

        appendRuntimeLog("using ESM entrypoint fallback: \(mjsEntrypointURL.path)")
        return mjsEntrypointURL
    }

    private func reserveLoopbackPort() throws -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw T3RuntimeError.startupTimeout
        }
        defer { close(socketFD) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            throw T3RuntimeError.startupTimeout
        }

        var assignedAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)

        let nameResult = withUnsafeMutablePointer(to: &assignedAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }

        guard nameResult == 0 else {
            throw T3RuntimeError.startupTimeout
        }

        return Int(UInt16(bigEndian: assignedAddress.sin_port))
    }

    private func launchProcess(
        entrypointURL: URL,
        port: Int,
        stateDirectory: URL,
        workingDirectory: String
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
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)

        let runtimeArguments = [
            entrypointURL.path,
            "--mode", "web",
            "--host", "127.0.0.1",
            "--port", String(port),
            "--state-dir", stateDirectory.path,
            "--no-browser",
            "--auto-bootstrap-project-from-cwd"
        ]

        var runtimePathDirectories: [String] = []
        if let nodeExecutable = resolveRuntimeExecutablePath("node") {
            process.executableURL = URL(fileURLWithPath: nodeExecutable)
            process.arguments = runtimeArguments
            appendRuntimeLog("resolved node executable: \(nodeExecutable)")
            runtimePathDirectories.append(
                URL(fileURLWithPath: nodeExecutable, isDirectory: false)
                    .deletingLastPathComponent()
                    .path
            )
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node"] + runtimeArguments
            appendRuntimeLog("node resolution fallback: using /usr/bin/env node")
        }

        if let codexExecutable = resolveRuntimeExecutablePath("codex") {
            appendRuntimeLog("resolved codex executable: \(codexExecutable)")
            runtimePathDirectories.append(
                URL(fileURLWithPath: codexExecutable, isDirectory: false)
                    .deletingLastPathComponent()
                    .path
            )
        } else {
            appendRuntimeLog("codex executable not resolved during launch; relying on inherited PATH")
        }

        var env = ProcessInfo.processInfo.environment
        env["T3CODE_MODE"] = "web"
        env["T3CODE_HOST"] = "127.0.0.1"
        env["T3CODE_PORT"] = String(port)
        env["T3CODE_STATE_DIR"] = stateDirectory.path
        env["T3CODE_NO_BROWSER"] = "1"
        if !runtimePathDirectories.isEmpty {
            env["PATH"] = mergedPath(prepending: runtimePathDirectories, existingPath: env["PATH"])
        }

        if let isolatedZdotDir = prepareIsolatedZdotDir() {
            env["ZDOTDIR"] = isolatedZdotDir.path
            appendRuntimeLog("using isolated ZDOTDIR: \(isolatedZdotDir.path)")
        }

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

    private func mergedPath(prepending directories: [String], existingPath: String?) -> String {
        var combined: [String] = directories
        if let existingPath {
            combined.append(contentsOf: existingPath.split(separator: ":").map(String.init))
        }

        var seen: Set<String> = []
        var unique: [String] = []
        for directory in combined {
            guard !directory.isEmpty else { continue }
            if seen.insert(directory).inserted {
                unique.append(directory)
            }
        }
        return unique.joined(separator: ":")
    }

    private func prepareIsolatedZdotDir() -> URL? {
        let zdotDir = paths.sessionDirectory.appendingPathComponent("codex-zdotdir", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: zdotDir, withIntermediateDirectories: true)

            // Keep login/non-login shells quiet and deterministic for Codex shell snapshots.
            for filename in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
                let fileURL = zdotDir.appendingPathComponent(filename, isDirectory: false)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    try "".write(to: fileURL, atomically: true, encoding: .utf8)
                }
            }

            return zdotDir
        } catch {
            appendRuntimeLog("failed to prepare isolated ZDOTDIR: \(error.localizedDescription)")
            return nil
        }
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
            Logger.error("Failed writing T3 runtime log data: \(error.localizedDescription)")
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
                Logger.error("Failed opening T3 runtime log: \(error.localizedDescription)")
                return
            }
        }

        appendLogData(data)
    }

    private func handleWebContentTermination(_ webView: WKWebView) {
        webContentTerminationCount += 1
        appendRuntimeLog("web content terminated count=\(webContentTerminationCount)")

        guard case .live(let urlString) = state,
              let url = URL(string: urlString) else {
            return
        }

        if webContentTerminationCount <= maxWebContentReloadAttempts {
            appendRuntimeLog("reloading embedded content after WebContent termination")
            webView.load(URLRequest(url: url))
            return
        }

        appendRuntimeLog("web content termination retry budget exhausted; terminating runtime process")
        state = .failed(
            message: "Embedded browser process crashed repeatedly. Open logs for details.",
            logPath: paths.runtimeLogPath.path
        )
        terminateProcess()
    }

    private func isRetryableStartupError(_ error: Error) -> Bool {
        guard let runtimeError = error as? T3RuntimeError else {
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
        guard let runtimeError = error as? T3RuntimeError else {
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
