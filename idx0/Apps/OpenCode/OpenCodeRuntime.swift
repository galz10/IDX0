import AppKit
import Darwin
import Foundation
import WebKit

struct OpenCodeRuntimePaths: Sendable {
    let rootDirectory: URL
    let sessionsDirectory: URL
    let sessionDirectory: URL
    let xdgConfigHomeDirectory: URL
    let xdgDataHomeDirectory: URL
    let xdgCacheHomeDirectory: URL
    let xdgStateHomeDirectory: URL
    let logsDirectory: URL
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
                .appendingPathComponent("opencode", isDirectory: true)
        }

        rootDirectory = idx0Root
        sessionsDirectory = idx0Root.appendingPathComponent("sessions", isDirectory: true)
        sessionDirectory = sessionsDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        xdgConfigHomeDirectory = sessionDirectory.appendingPathComponent("xdg-config", isDirectory: true)
        xdgDataHomeDirectory = sessionDirectory.appendingPathComponent("xdg-data", isDirectory: true)
        xdgCacheHomeDirectory = sessionDirectory.appendingPathComponent("xdg-cache", isDirectory: true)
        xdgStateHomeDirectory = sessionDirectory.appendingPathComponent("xdg-state", isDirectory: true)
        logsDirectory = sessionDirectory.appendingPathComponent("logs", isDirectory: true)
        runtimeLogPath = logsDirectory.appendingPathComponent("runtime.log", isDirectory: false)
    }

    func ensureBaseDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: xdgConfigHomeDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: xdgDataHomeDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: xdgCacheHomeDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: xdgStateHomeDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }
}

struct OpenCodeSessionState: Sendable {
    let xdgConfigHome: URL
    let xdgDataHome: URL
    let xdgCacheHome: URL
    let xdgStateHome: URL

    var environmentOverrides: [String: String] {
        [
            "XDG_CONFIG_HOME": xdgConfigHome.path,
            "XDG_DATA_HOME": xdgDataHome.path,
            "XDG_CACHE_HOME": xdgCacheHome.path,
            "XDG_STATE_HOME": xdgStateHome.path,
        ]
    }
}

final class OpenCodeStateSnapshotManager {
    func prepareSessionState(
        paths: OpenCodeRuntimePaths,
        fileManager: FileManager = .default
    ) throws -> OpenCodeSessionState {
        try paths.ensureBaseDirectories(fileManager: fileManager)
        return OpenCodeSessionState(
            xdgConfigHome: paths.xdgConfigHomeDirectory,
            xdgDataHome: paths.xdgDataHomeDirectory,
            xdgCacheHome: paths.xdgCacheHomeDirectory,
            xdgStateHome: paths.xdgStateHomeDirectory
        )
    }

    func removeSessionState(
        paths: OpenCodeRuntimePaths,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: paths.sessionDirectory)
    }
}

enum OpenCodeTileRuntimeState: Equatable, Sendable {
    case idle
    case starting
    case live(urlString: String)
    case failed(message: String, logPath: String?)

    var displayMessage: String {
        switch self {
        case .idle:
            return "Ready"
        case .starting:
            return "Starting OpenCode..."
        case .live:
            return "Live"
        case .failed(let message, _):
            return message
        }
    }
}

enum OpenCodeRuntimeError: LocalizedError, Sendable {
    case missingExecutable
    case missingNodeExecutable
    case commandFailed(command: String, code: Int32, stderr: String?)
    case startupTimeout
    case processExitedBeforeReady
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            return "OpenCode CLI was not found on PATH. Install it and retry (for example: `brew install sst/tap/opencode`), then verify `which opencode`."
        case .missingNodeExecutable:
            return "Node.js was not found on PATH, but this OpenCode install requires it. Install Node (or make it visible to GUI apps) and retry."
        case .commandFailed(let command, let code, let stderr):
            if let stderr, !stderr.isEmpty {
                return "Command failed (\(code)): \(command)\n\(stderr)"
            }
            return "Command failed (\(code)): \(command)"
        case .startupTimeout:
            return "OpenCode did not become ready in time."
        case .processExitedBeforeReady:
            return "OpenCode process exited before it became ready."
        case .cancelled:
            return "Operation cancelled."
        }
    }
}

@MainActor
final class OpenCodeTileController: ObservableObject, NiriAppTileRuntimeControlling {
    @Published private(set) var state: OpenCodeTileRuntimeState = .idle

    let sessionID: UUID
    let itemID: UUID
    let webView: WKWebView

    private let launchDirectoryProvider: () -> String?
    private let snapshotManager: OpenCodeStateSnapshotManager
    private let processRunner: any ProcessRunnerProtocol
    private let paths: OpenCodeRuntimePaths
    private let executableSearchDirectoriesOverride: [String]?
    private let baseEnvironmentOverride: [String: String]?

    private let readinessIntervalNanoseconds: UInt64
    private let readinessTimeoutSeconds: TimeInterval
    private let defaultZoom: CGFloat = 0.5
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
    private var processExitedDuringStartup = false

    init(
        sessionID: UUID,
        itemID: UUID,
        launchDirectoryProvider: @escaping () -> String?,
        snapshotManager: OpenCodeStateSnapshotManager,
        processRunner: any ProcessRunnerProtocol = ProcessRunner(),
        rootDirectoryOverride: URL? = nil,
        executableSearchDirectoriesOverride: [String]? = nil,
        baseEnvironmentOverride: [String: String]? = nil,
        readinessIntervalNanoseconds: UInt64 = 250_000_000,
        readinessTimeoutSeconds: TimeInterval = 20
    ) {
        self.sessionID = sessionID
        self.itemID = itemID
        self.launchDirectoryProvider = launchDirectoryProvider
        self.snapshotManager = snapshotManager
        self.processRunner = processRunner
        self.paths = OpenCodeRuntimePaths(sessionID: sessionID, rootDirectoryOverride: rootDirectoryOverride)
        self.executableSearchDirectoriesOverride = executableSearchDirectoriesOverride
        self.baseEnvironmentOverride = baseEnvironmentOverride
        self.readinessIntervalNanoseconds = readinessIntervalNanoseconds
        self.readinessTimeoutSeconds = readinessTimeoutSeconds

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.pageZoom = defaultZoom

        let delegate = EmbeddedWebViewDelegate(logLabel: "OpenCode[\(sessionID.uuidString)]") { [weak self] view in
            self?.handleWebContentTermination(view)
        }
        webView.navigationDelegate = delegate
        webViewDelegate = delegate
    }

    func ensureStarted() {
        guard startTask == nil else { return }

        switch state {
        case .idle, .failed:
            break
        case .starting, .live:
            return
        }

        userStopped = false
        processExitedDuringStartup = false
        startTask = Task { [weak self] in
            guard let self else { return }
            await self.runStartupSequence()
            self.startTask = nil
        }
    }

    func retry() {
        stop()
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

    func resolveOpenCodeExecutable() async throws -> String {
        if let directPath = resolveExecutableFromSearchDirectories(
            named: "opencode",
            searchDirectories: executableSearchDirectories()
        ) {
            return directPath
        }

        let probes: [(executable: String, arguments: [String], command: String)] = [
            ("/usr/bin/which", ["opencode"], "which opencode"),
            ("/bin/zsh", ["-lc", "whence -p opencode"], "zsh -lc 'whence -p opencode'"),
            ("/bin/zsh", ["-ilc", "whence -p opencode"], "zsh -ilc 'whence -p opencode'")
        ]

        var failedProbeCommands: [String] = []

        for probe in probes {
            do {
                let result = try await processRunner.run(
                    executable: probe.executable,
                    arguments: probe.arguments,
                    currentDirectory: nil
                )

                guard result.exitCode == 0 else { continue }
                guard let resolvedPath = firstExecutablePath(from: result.stdout) else { continue }
                guard FileManager.default.isExecutableFile(atPath: resolvedPath) else { continue }
                return resolvedPath
            } catch {
                failedProbeCommands.append("\(probe.command): \(error.localizedDescription)")
            }
        }

        if failedProbeCommands.count == probes.count {
            throw OpenCodeRuntimeError.commandFailed(
                command: probes.map(\.command).joined(separator: " | "),
                code: -1,
                stderr: failedProbeCommands.joined(separator: "\n")
            )
        }

        throw OpenCodeRuntimeError.missingExecutable
    }

    private func resolveExecutableFromSearchDirectories(
        named executable: String,
        searchDirectories: [String]
    ) -> String? {
        for directory in searchDirectories where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(executable, isDirectory: false)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func executableSearchDirectories() -> [String] {
        if let executableSearchDirectoriesOverride {
            return executableSearchDirectoriesOverride
        }

        let environment = ProcessInfo.processInfo.environment
        var directories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        directories.append(contentsOf: defaultExecutableSearchDirectories(homeDirectory: NSHomeDirectory()))
        return uniqueDirectories(directories)
    }

    private func defaultExecutableSearchDirectories(homeDirectory: String) -> [String] {
        [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "\(homeDirectory)/.asdf/shims",
            "\(homeDirectory)/.volta/bin",
            "\(homeDirectory)/.cargo/bin",
            "\(homeDirectory)/.local/bin",
            "\(homeDirectory)/bin",
            "\(homeDirectory)/.bun/bin",
            "\(homeDirectory)/Library/pnpm",
            "\(homeDirectory)/.npm-global/bin",
            "\(homeDirectory)/.yarn/bin",
            "\(homeDirectory)/.config/yarn/global/node_modules/.bin",
            "\(homeDirectory)/.nvm/versions/node/current/bin"
        ]
    }

    private func uniqueDirectories(_ directories: [String]) -> [String] {
        var seen: Set<String> = []
        var unique: [String] = []

        for directory in directories where !directory.isEmpty {
            if seen.insert(directory).inserted {
                unique.append(directory)
            }
        }

        return unique
    }

    private func firstExecutablePath(from output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty && $0.hasPrefix("/") })
    }

    private func runStartupSequence() async {
        do {
            try await startupAttempt()
        } catch {
            if userStopped || Task.isCancelled {
                return
            }

            let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            appendRuntimeLog("startup failed: \(description)")
            state = .failed(message: description, logPath: paths.runtimeLogPath.path)
        }
    }

    private func startupAttempt() async throws {
        let sessionState = try snapshotManager.prepareSessionState(paths: paths)
        if userStopped || Task.isCancelled {
            throw OpenCodeRuntimeError.cancelled
        }

        let executablePath = try await resolveOpenCodeExecutable()
        let runtimeEnvironment = try await buildRuntimeEnvironment(
            executablePath: executablePath,
            environmentOverrides: sessionState.environmentOverrides
        )
        let port = try reserveLoopbackPort()
        let launchDirectory = resolvedLaunchDirectory()
        var runtimeEnvironmentWithLaunchDirectory = runtimeEnvironment
        runtimeEnvironmentWithLaunchDirectory["PWD"] = launchDirectory
        runtimeEnvironmentWithLaunchDirectory["INIT_CWD"] = launchDirectory

        state = .starting
        processExitedDuringStartup = false
        try launchProcess(
            executablePath: executablePath,
            port: port,
            launchDirectory: launchDirectory,
            environment: runtimeEnvironmentWithLaunchDirectory
        )

        let ready = await waitForServerReady(port: port)
        guard ready else {
            let exitedBeforeReady = processExitedDuringStartup || (process?.isRunning == false)
            terminateProcess()

            if userStopped || Task.isCancelled {
                throw OpenCodeRuntimeError.cancelled
            }
            if exitedBeforeReady {
                throw OpenCodeRuntimeError.processExitedBeforeReady
            }
            throw OpenCodeRuntimeError.startupTimeout
        }

        if userStopped || Task.isCancelled {
            terminateProcess()
            throw OpenCodeRuntimeError.cancelled
        }

        let url = URL(string: "http://127.0.0.1:\(port)")!
        webContentTerminationCount = 0
        webView.load(URLRequest(url: url))
        state = .live(urlString: url.absoluteString)
        appendRuntimeLog("runtime live at \(url.absoluteString)")
    }

    private func reserveLoopbackPort() throws -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw OpenCodeRuntimeError.startupTimeout
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
            throw OpenCodeRuntimeError.startupTimeout
        }

        var assignedAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)

        let nameResult = withUnsafeMutablePointer(to: &assignedAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard nameResult == 0 else {
            throw OpenCodeRuntimeError.startupTimeout
        }

        return Int(UInt16(bigEndian: assignedAddress.sin_port))
    }

    private func resolvedLaunchDirectory() -> String {
        if let raw = launchDirectoryProvider() {
            let expanded = NSString(string: raw).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
                return expanded
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func launchProcess(
        executablePath: String,
        port: Int,
        launchDirectory: String,
        environment: [String: String]
    ) throws {
        terminateProcess()

        try FileManager.default.createDirectory(at: paths.runtimeLogPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: paths.runtimeLogPath.path) {
            _ = FileManager.default.createFile(atPath: paths.runtimeLogPath.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: paths.runtimeLogPath)
        try handle.seekToEnd()
        logHandle = handle

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath, isDirectory: false)
        process.currentDirectoryURL = URL(fileURLWithPath: launchDirectory, isDirectory: true)
        process.arguments = [
            "--print-logs",
            "--log-level", "WARN",
            "serve",
            "--hostname", "127.0.0.1",
            "--port", String(port),
        ]

        process.environment = environment

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

        appendRuntimeLog("spawned opencode pid=\(process.processIdentifier) port=\(port) cwd=\(launchDirectory)")
    }

    private func buildRuntimeEnvironment(
        executablePath: String,
        environmentOverrides: [String: String]
    ) async throws -> [String: String] {
        var environment = baseEnvironmentOverride ?? ProcessInfo.processInfo.environment
        var pathDirectories = uniqueDirectories(
            ((environment["PATH"] ?? "")
                .split(separator: ":")
                .map(String.init)) +
                executableSearchDirectories() +
                [URL(fileURLWithPath: executablePath, isDirectory: false).deletingLastPathComponent().path]
        )

        let requiresNode = executableRequiresNode(atPath: executablePath)
        if let nodeExecutablePath = await resolveOptionalExecutablePath("node", searchDirectories: pathDirectories) {
            let nodeDirectory = URL(fileURLWithPath: nodeExecutablePath, isDirectory: false)
                .deletingLastPathComponent()
                .path
            pathDirectories = uniqueDirectories(pathDirectories + [nodeDirectory])
            appendRuntimeLog("resolved node executable: \(nodeExecutablePath)")
        } else if requiresNode {
            throw OpenCodeRuntimeError.missingNodeExecutable
        }

        environment["PATH"] = pathDirectories.joined(separator: ":")

        for (key, value) in environmentOverrides {
            environment[key] = value
        }

        return environment
    }

    private func executableRequiresNode(atPath path: String) -> Bool {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }
        guard let shebangLine = content.split(whereSeparator: \.isNewline).first else {
            return false
        }
        let shebang = String(shebangLine).trimmingCharacters(in: .whitespacesAndNewlines)
        return shebang.hasPrefix("#!") && shebang.contains("node")
    }

    private func resolveOptionalExecutablePath(
        _ executable: String,
        searchDirectories: [String]
    ) async -> String? {
        if let directPath = resolveExecutableFromSearchDirectories(
            named: executable,
            searchDirectories: searchDirectories
        ) {
            return directPath
        }

        let probes: [(executable: String, arguments: [String])] = [
            ("/usr/bin/which", [executable]),
            ("/bin/zsh", ["-lc", "whence -p \(executable)"]),
            ("/bin/zsh", ["-ilc", "whence -p \(executable)"])
        ]

        for probe in probes {
            do {
                let result = try await processRunner.run(
                    executable: probe.executable,
                    arguments: probe.arguments,
                    currentDirectory: nil
                )
                guard result.exitCode == 0 else { continue }
                guard let resolvedPath = firstExecutablePath(from: result.stdout) else { continue }
                guard FileManager.default.isExecutableFile(atPath: resolvedPath) else { continue }
                return resolvedPath
            } catch {
                continue
            }
        }

        return nil
    }

    private func waitForServerReady(port: Int) async -> Bool {
        let healthURL = URL(string: "http://127.0.0.1:\(port)/global/health")!
        let deadline = Date().addingTimeInterval(readinessTimeoutSeconds)

        while Date() < deadline {
            if Task.isCancelled || userStopped {
                return false
            }
            if processExitedDuringStartup || process?.isRunning == false {
                return false
            }
            if await probeServerHealth(url: healthURL) {
                return true
            }
            try? await Task.sleep(nanoseconds: readinessIntervalNanoseconds)
        }

        return false
    }

    private func probeServerHealth(url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return false
            }
            return (200 ..< 300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func handleProcessExit(_ terminatedProcess: Process) {
        appendRuntimeLog(
            "process exited status=\(terminatedProcess.terminationStatus) reason=\(terminatedProcess.terminationReason.rawValue)"
        )

        if startTask != nil {
            processExitedDuringStartup = true
        }
        terminateProcess()

        guard !userStopped else { return }
        if case .failed = state { return }
        if startTask == nil {
            state = .failed(
                message: "OpenCode process exited unexpectedly.",
                logPath: paths.runtimeLogPath.path
            )
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
        process = nil

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
            Logger.error("Failed writing OpenCode runtime log data: \(error.localizedDescription)")
        }
    }

    private func appendRuntimeLog(_ line: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "[\(timestamp)] \(line)\n".data(using: .utf8) else { return }

        if logHandle == nil {
            do {
                try FileManager.default.createDirectory(at: paths.runtimeLogPath.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: paths.runtimeLogPath.path) {
                    _ = FileManager.default.createFile(atPath: paths.runtimeLogPath.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: paths.runtimeLogPath)
                try handle.seekToEnd()
                logHandle = handle
            } catch {
                Logger.error("Failed opening OpenCode runtime log: \(error.localizedDescription)")
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
}
