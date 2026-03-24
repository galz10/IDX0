import AppKit
import CommonCrypto
import Darwin
import Foundation
import WebKit

struct VSCodeArtifactManifest: Codable, Equatable, Sendable {
    let platform: String
    let downloadURL: String
    let sha256: String
    let extractDirectoryName: String
}

struct VSCodeBuildManifest: Codable, Equatable, Sendable {
    static let defaultVersion = "4.112.0"

    let runtimeName: String
    let version: String
    let executableRelativePath: String
    let artifacts: [VSCodeArtifactManifest]

    static let `default` = VSCodeBuildManifest(
        runtimeName: "code-server",
        version: defaultVersion,
        executableRelativePath: "bin/code-server",
        artifacts: [
            VSCodeArtifactManifest(
                platform: "macos-arm64",
                downloadURL: "https://github.com/coder/code-server/releases/download/v4.112.0/code-server-4.112.0-macos-arm64.tar.gz",
                sha256: "1a0a3cfbd7b5c946c1bbdf56a2b0a92b2995f5da316ca5f599e5ec782c00fb71",
                extractDirectoryName: "code-server-4.112.0-macos-arm64"
            ),
            VSCodeArtifactManifest(
                platform: "macos-amd64",
                downloadURL: "https://github.com/coder/code-server/releases/download/v4.112.0/code-server-4.112.0-macos-amd64.tar.gz",
                sha256: "f1ad6c133ae6e46904af4d81a55f415382c6b7eb83df8383deaea90c9b7fd58a",
                extractDirectoryName: "code-server-4.112.0-macos-amd64"
            )
        ]
    )

    static func loadFromBundle(_ bundle: Bundle = .main) -> VSCodeBuildManifest {
        guard let url = bundle.url(forResource: "openvscode-build-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(VSCodeBuildManifest.self, from: data)
        else {
            return .default
        }
        return decoded
    }

    func artifact(forCurrentPlatform platformOverride: String? = nil) -> VSCodeArtifactManifest? {
        let platform = platformOverride ?? Self.currentPlatformIdentifier()
        return artifacts.first(where: { $0.platform == platform })
    }

    static func currentPlatformIdentifier() -> String {
#if arch(arm64)
        return "macos-arm64"
#elseif arch(x86_64)
        return "macos-amd64"
#else
        return "macos-unsupported"
#endif
    }
}

struct VSCodeRuntimePaths: Sendable {
    let rootDirectory: URL
    let runtimeDirectory: URL
    let runtimeVersionsDirectory: URL
    let runtimeInstallRecordPath: URL
    let downloadsDirectory: URL
    let provisionLogPath: URL
    let profilesDirectory: URL
    let sessionsDirectory: URL
    let sessionDirectory: URL
    let sessionUserDataDirectory: URL
    let sessionExtensionsDirectory: URL
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
                .appendingPathComponent("openvscode", isDirectory: true)
        }

        rootDirectory = idx0Root
        runtimeDirectory = idx0Root.appendingPathComponent("runtime", isDirectory: true)
        runtimeVersionsDirectory = runtimeDirectory.appendingPathComponent("versions", isDirectory: true)
        runtimeInstallRecordPath = runtimeDirectory.appendingPathComponent("install-record.json", isDirectory: false)
        downloadsDirectory = runtimeDirectory.appendingPathComponent("downloads", isDirectory: true)
        provisionLogPath = idx0Root
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("provision.log", isDirectory: false)
        profilesDirectory = idx0Root.appendingPathComponent("profiles", isDirectory: true)

        sessionsDirectory = idx0Root.appendingPathComponent("sessions", isDirectory: true)
        sessionDirectory = sessionsDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        sessionUserDataDirectory = sessionDirectory.appendingPathComponent("user-data", isDirectory: true)
        sessionExtensionsDirectory = sessionDirectory.appendingPathComponent("extensions", isDirectory: true)
        runtimeLogPath = sessionDirectory.appendingPathComponent("runtime.log", isDirectory: false)
    }

    func ensureBaseDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeVersionsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: provisionLogPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    }
}

enum VSCodeTileRuntimeState: Equatable, Sendable {
    case idle
    case provisioning
    case downloading
    case extracting
    case starting
    case live(urlString: String)
    case failed(message: String, logPath: String?)

    var displayMessage: String {
        switch self {
        case .idle:
            return "Ready"
        case .provisioning:
            return "Preparing VS Code runtime..."
        case .downloading:
            return "Downloading VS Code runtime..."
        case .extracting:
            return "Installing VS Code runtime..."
        case .starting:
            return "Starting VS Code..."
        case .live:
            return "Live"
        case .failed(let message, _):
            return message
        }
    }
}

enum VSCodeRuntimeError: LocalizedError, Sendable {
    case unsupportedPlatform(String)
    case invalidDownloadURL(String)
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case missingExecutable(String)
    case commandFailed(command: String, code: Int32, stderr: String?)
    case startupTimeout
    case processExitedBeforeReady
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform(let platform):
            return "VS Code runtime is not available for platform: \(platform)"
        case .invalidDownloadURL(let raw):
            return "Invalid runtime download URL: \(raw)"
        case .downloadFailed(let description):
            return "Runtime download failed: \(description)"
        case .checksumMismatch(let expected, let actual):
            return "Downloaded runtime checksum mismatch. Expected \(expected), got \(actual)."
        case .missingExecutable(let path):
            return "Runtime executable missing: \(path)"
        case .commandFailed(let command, let code, let stderr):
            if let stderr, !stderr.isEmpty {
                return "Command failed (\(code)): \(command)\n\(stderr)"
            }
            return "Command failed (\(code)): \(command)"
        case .startupTimeout:
            return "VS Code did not become ready in time."
        case .processExitedBeforeReady:
            return "VS Code process exited before it became ready."
        case .cancelled:
            return "Operation cancelled."
        }
    }
}

private struct VSCodeInstallRecord: Codable, Sendable {
    let runtimeName: String
    let version: String
    let platform: String
    let sha256: String
    let runtimeDirectoryName: String
    let executableRelativePath: String
    let installedAt: Date
}

actor OpenVSCodeProvisioner {
    private let processRunner: any ProcessRunnerProtocol
    private let fileManager: FileManager
    private var installTask: Task<URL, Error>?

    init(processRunner: any ProcessRunnerProtocol = ProcessRunner(), fileManager: FileManager = .default) {
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    func ensureRuntimeInstalled(
        manifest: VSCodeBuildManifest,
        paths: VSCodeRuntimePaths
    ) async throws -> URL {
        if let existing = try? reusableRuntimeIfAvailable(manifest: manifest, paths: paths) {
            return existing
        }

        if let existingTask = installTask {
            return try await existingTask.value
        }

        let task = Task { [weak self] () -> URL in
            guard let self else { throw VSCodeRuntimeError.cancelled }
            return try await self.performInstall(manifest: manifest, paths: paths)
        }

        installTask = task
        do {
            let installed = try await task.value
            installTask = nil
            return installed
        } catch {
            installTask = nil
            throw error
        }
    }

    private func reusableRuntimeIfAvailable(manifest: VSCodeBuildManifest, paths: VSCodeRuntimePaths) throws -> URL {
        guard fileManager.fileExists(atPath: paths.runtimeInstallRecordPath.path) else {
            throw VSCodeRuntimeError.missingExecutable(paths.runtimeInstallRecordPath.path)
        }

        let data = try Data(contentsOf: paths.runtimeInstallRecordPath)
        let record = try JSONDecoder().decode(VSCodeInstallRecord.self, from: data)
        let currentPlatform = VSCodeBuildManifest.currentPlatformIdentifier()

        guard record.runtimeName == manifest.runtimeName,
              record.version == manifest.version,
              record.platform == currentPlatform,
              let artifact = manifest.artifact(forCurrentPlatform: currentPlatform),
              record.sha256.lowercased() == artifact.sha256.lowercased()
        else {
            throw VSCodeRuntimeError.missingExecutable("runtime manifest mismatch")
        }

        let runtimeDirectory = paths.runtimeVersionsDirectory.appendingPathComponent(record.runtimeDirectoryName, isDirectory: true)
        let executableURL = runtimeDirectory.appendingPathComponent(record.executableRelativePath, isDirectory: false)
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw VSCodeRuntimeError.missingExecutable(executableURL.path)
        }

        return runtimeDirectory
    }

    private func performInstall(
        manifest: VSCodeBuildManifest,
        paths: VSCodeRuntimePaths
    ) async throws -> URL {
        try paths.ensureBaseDirectories(fileManager: fileManager)

        let currentPlatform = VSCodeBuildManifest.currentPlatformIdentifier()
        guard let artifact = manifest.artifact(forCurrentPlatform: currentPlatform) else {
            throw VSCodeRuntimeError.unsupportedPlatform(currentPlatform)
        }

        guard let downloadURL = URL(string: artifact.downloadURL) else {
            throw VSCodeRuntimeError.invalidDownloadURL(artifact.downloadURL)
        }

        appendProvisionLog(paths: paths, line: "== provision start \(Date())")
        appendProvisionLog(paths: paths, line: "platform=\(currentPlatform) url=\(downloadURL.absoluteString)")

        let archiveURL = paths.downloadsDirectory.appendingPathComponent("\(artifact.extractDirectoryName).tar.gz", isDirectory: false)
        let extractTarget = paths.runtimeVersionsDirectory
        let runtimeDirectory = extractTarget.appendingPathComponent(artifact.extractDirectoryName, isDirectory: true)

        if fileManager.fileExists(atPath: archiveURL.path) {
            try? fileManager.removeItem(at: archiveURL)
        }

        do {
            let (temporaryURL, response) = try await URLSession.shared.download(from: downloadURL)
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
                throw VSCodeRuntimeError.downloadFailed("non-2xx response")
            }
            try fileManager.moveItem(at: temporaryURL, to: archiveURL)
        } catch {
            throw VSCodeRuntimeError.downloadFailed(error.localizedDescription)
        }

        let actualSHA = try sha256(forFileAt: archiveURL)
        let expectedSHA = artifact.sha256.lowercased()
        guard actualSHA == expectedSHA else {
            try? fileManager.removeItem(at: archiveURL)
            throw VSCodeRuntimeError.checksumMismatch(expected: expectedSHA, actual: actualSHA)
        }

        if fileManager.fileExists(atPath: runtimeDirectory.path) {
            try? fileManager.removeItem(at: runtimeDirectory)
        }

        try await runChecked(
            executable: "/usr/bin/tar",
            arguments: ["-xzf", archiveURL.path, "-C", extractTarget.path],
            currentDirectory: extractTarget.path,
            paths: paths
        )

        let executableURL = runtimeDirectory.appendingPathComponent(manifest.executableRelativePath, isDirectory: false)
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw VSCodeRuntimeError.missingExecutable(executableURL.path)
        }

        let record = VSCodeInstallRecord(
            runtimeName: manifest.runtimeName,
            version: manifest.version,
            platform: currentPlatform,
            sha256: expectedSHA,
            runtimeDirectoryName: artifact.extractDirectoryName,
            executableRelativePath: manifest.executableRelativePath,
            installedAt: Date()
        )
        let recordData = try JSONEncoder().encode(record)
        try recordData.write(to: paths.runtimeInstallRecordPath, options: .atomic)

        appendProvisionLog(paths: paths, line: "== provision complete \(Date())")
        return runtimeDirectory
    }

    private func runChecked(
        executable: String,
        arguments: [String],
        currentDirectory: String?,
        paths: VSCodeRuntimePaths
    ) async throws {
        let command = ([executable] + arguments).joined(separator: " ")
        appendProvisionLog(paths: paths, line: "$ \(command)")

        let result = try await processRunner.run(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory
        )

        if !result.stdout.isEmpty {
            appendProvisionLog(paths: paths, line: result.stdout)
        }
        if !result.stderr.isEmpty {
            appendProvisionLog(paths: paths, line: result.stderr)
        }

        guard result.exitCode == 0 else {
            throw VSCodeRuntimeError.commandFailed(
                command: command,
                code: result.exitCode,
                stderr: result.stderr.isEmpty ? nil : result.stderr
            )
        }
    }

    private func appendProvisionLog(paths: VSCodeRuntimePaths, line: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logLine = "[\(timestamp)] \(line)\n"

        do {
            try fileManager.createDirectory(at: paths.provisionLogPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: paths.provisionLogPath.path) {
                try logLine.write(to: paths.provisionLogPath, atomically: true, encoding: .utf8)
                return
            }
            let handle = try FileHandle(forWritingTo: paths.provisionLogPath)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = logLine.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } catch {
            Logger.error("Failed to append VS Code provision log: \(error.localizedDescription)")
        }
    }

    private func sha256(forFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class VSCodeStateSnapshotManager {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func prepareSessionState(
        paths: VSCodeRuntimePaths,
        profileSeedPath: String
    ) throws -> (userDataDir: URL, extensionsDir: URL) {
        try paths.ensureBaseDirectories(fileManager: fileManager)

        let profileID = stableProfileID(seedPath: profileSeedPath)
        let profileDirectory = paths.profilesDirectory.appendingPathComponent(profileID, isDirectory: true)
        let profileUserDataDirectory = profileDirectory.appendingPathComponent("user-data", isDirectory: true)
        let profileExtensionsDirectory = profileDirectory.appendingPathComponent("extensions", isDirectory: true)

        try fileManager.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        try migrateLegacySessionStateIfNeeded(
            from: paths.sessionUserDataDirectory,
            to: profileUserDataDirectory
        )
        try migrateLegacySessionStateIfNeeded(
            from: paths.sessionExtensionsDirectory,
            to: profileExtensionsDirectory
        )

        try fileManager.createDirectory(at: profileUserDataDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: profileExtensionsDirectory, withIntermediateDirectories: true)

        let userDirectory = profileUserDataDirectory.appendingPathComponent("User", isDirectory: true)
        try fileManager.createDirectory(at: userDirectory, withIntermediateDirectories: true)

        let settingsPath = userDirectory.appendingPathComponent("settings.json", isDirectory: false)
        try upsertSessionSettings(at: settingsPath)

        return (profileUserDataDirectory, profileExtensionsDirectory)
    }

    func removeSessionState(paths: VSCodeRuntimePaths) {
        // Keep profile-backed user data and extensions so trust/theme/zoom persist.
        try? fileManager.removeItem(at: paths.sessionDirectory)
    }

    private func migrateLegacySessionStateIfNeeded(from legacyPath: URL, to profilePath: URL) throws {
        guard fileManager.fileExists(atPath: legacyPath.path),
              !fileManager.fileExists(atPath: profilePath.path)
        else {
            return
        }
        try fileManager.copyItem(at: legacyPath, to: profilePath)
    }

    private func stableProfileID(seedPath: String) -> String {
        let expanded = NSString(string: seedPath).expandingTildeInPath
        let canonicalPath = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
        let hash = sha256Hex(canonicalPath).prefix(16)
        let name = sanitizeFilenameComponent(URL(fileURLWithPath: canonicalPath).lastPathComponent)
        if name.isEmpty {
            return String(hash)
        }
        return "\(name)-\(hash)"
    }

    private func sha256Hex(_ value: String) -> String {
        let data = Data(value.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func sanitizeFilenameComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mappedScalars = value.unicodeScalars.map { scalar -> UnicodeScalar in
            allowed.contains(scalar) ? scalar : "-"
        }
        let mapped = String(String.UnicodeScalarView(mappedScalars))
        let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return trimmed.isEmpty ? "workspace" : trimmed
    }

    private func upsertSessionSettings(at settingsPath: URL) throws {
        var root = try loadSettingsJSON(from: settingsPath)
        if root["telemetry.telemetryLevel"] == nil {
            root["telemetry.telemetryLevel"] = "off"
        }
        if root["extensions.autoCheckUpdates"] == nil {
            root["extensions.autoCheckUpdates"] = false
        }
        if root["extensions.autoUpdate"] == nil {
            root["extensions.autoUpdate"] = false
        }
        if root["update.mode"] == nil {
            root["update.mode"] = "none"
        }
        if root["security.workspace.trust.enabled"] == nil {
            root["security.workspace.trust.enabled"] = false
        }
        // OpenVSCode + recent Python extension can fail to start Jedi LSP due to
        // position-encoding incompatibilities; default to no language server.
        if root["python.languageServer"] == nil {
            root["python.languageServer"] = "None"
        }

        // Force disable web "debug by link" launch flow in embedded VS Code.
        root["debug.javascript.debugByLinkOptions"] = "off"

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsPath, options: .atomic)
    }

    private func loadSettingsJSON(from settingsPath: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: settingsPath.path) else {
            return [:]
        }

        let raw = try String(contentsOf: settingsPath, encoding: .utf8)
        let cleaned = stripJSONComments(from: raw)
        guard let data = cleaned.data(using: .utf8) else {
            return [:]
        }

        guard !data.isEmpty else {
            return [:]
        }

        do {
            let json = try JSONSerialization.jsonObject(with: data, options: [])
            return json as? [String: Any] ?? [:]
        } catch {
            return [:]
        }
    }

    private func stripJSONComments(from text: String) -> String {
        var output = String()
        var index = text.startIndex
        var isInString = false
        var isEscaped = false

        while index < text.endIndex {
            let character = text[index]

            if isInString {
                output.append(character)
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
                index = text.index(after: index)
                continue
            }

            if character == "\"" {
                isInString = true
                output.append(character)
                index = text.index(after: index)
                continue
            }

            if character == "/" {
                let next = text.index(after: index)
                if next < text.endIndex {
                    let nextChar = text[next]
                    if nextChar == "/" {
                        index = text.index(after: next)
                        while index < text.endIndex, text[index] != "\n" {
                            index = text.index(after: index)
                        }
                        continue
                    }
                    if nextChar == "*" {
                        index = text.index(after: next)
                        while index < text.endIndex {
                            let candidateEnd = text.index(after: index)
                            if text[index] == "*", candidateEnd < text.endIndex, text[candidateEnd] == "/" {
                                index = text.index(after: candidateEnd)
                                break
                            }
                            index = text.index(after: index)
                        }
                        continue
                    }
                }
            }

            output.append(character)
            index = text.index(after: index)
        }

        return output
    }
}

@MainActor
final class VSCodeTileController: ObservableObject, NiriAppTileRuntimeControlling {
    @Published private(set) var state: VSCodeTileRuntimeState = .idle

    let sessionID: UUID
    let itemID: UUID
    let webView: WKWebView

    private let launchDirectoryProvider: () -> String?
    private let profileSeedPathProvider: () -> String?
    private let provisioner: OpenVSCodeProvisioner
    private let snapshotManager: VSCodeStateSnapshotManager
    private let processRunner: any ProcessRunnerProtocol
    private let manifestProvider: () -> VSCodeBuildManifest
    private let paths: VSCodeRuntimePaths
    private let userDefaults: UserDefaults
    private let zoomDefaultsKey: String

    private let readinessIntervalNanoseconds: UInt64 = 250_000_000
    private let readinessTimeoutSeconds: TimeInterval = 20
    private let maxAutomaticRestarts = 3
    private let requiredExtensionIDs = ["ms-python.python"]
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
        profileSeedPathProvider: @escaping () -> String?,
        provisioner: OpenVSCodeProvisioner,
        snapshotManager: VSCodeStateSnapshotManager,
        processRunner: any ProcessRunnerProtocol = ProcessRunner(),
        manifestProvider: @escaping () -> VSCodeBuildManifest = { VSCodeBuildManifest.loadFromBundle() },
        userDefaults: UserDefaults = .standard
    ) {
        self.sessionID = sessionID
        self.itemID = itemID
        self.launchDirectoryProvider = launchDirectoryProvider
        self.profileSeedPathProvider = profileSeedPathProvider
        self.provisioner = provisioner
        self.snapshotManager = snapshotManager
        self.processRunner = processRunner
        self.manifestProvider = manifestProvider
        self.paths = VSCodeRuntimePaths(sessionID: sessionID)
        self.userDefaults = userDefaults

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)

        let zoomSeedPath = profileSeedPathProvider() ?? FileManager.default.homeDirectoryForCurrentUser.path
        zoomDefaultsKey = Self.zoomDefaultsKey(for: zoomSeedPath)
        webView.pageZoom = loadPersistedZoom()

        let delegate = EmbeddedWebViewDelegate(logLabel: "VSCode[\(sessionID.uuidString)]") { [weak self] view in
            self?.handleWebContentTermination(view)
        }
        webView.navigationDelegate = delegate
        webViewDelegate = delegate
    }

    func ensureStarted() {
        guard startTask == nil else { return }
        switch state {
        case .provisioning, .downloading, .extracting, .starting, .live:
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
        persistZoom(next)
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

    private func startupAttempt(manifest: VSCodeBuildManifest) async throws {
        try paths.ensureBaseDirectories()

        state = .provisioning
        let runtimeDirectory = try await provisioner.ensureRuntimeInstalled(
            manifest: manifest,
            paths: paths
        )

        if userStopped || Task.isCancelled {
            throw VSCodeRuntimeError.cancelled
        }

        let launchDirectory = launchDirectoryProvider() ?? FileManager.default.homeDirectoryForCurrentUser.path
        let profileSeedPath = profileSeedPathProvider() ?? launchDirectory
        let stateDirs = try snapshotManager.prepareSessionState(
            paths: paths,
            profileSeedPath: profileSeedPath
        )
        let port = try reserveLoopbackPort()

        let executableURL = runtimeDirectory.appendingPathComponent(manifest.executableRelativePath, isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw VSCodeRuntimeError.missingExecutable(executableURL.path)
        }

        await ensureRequiredExtensionsInstalled(
            executableURL: executableURL,
            userDataDir: stateDirs.userDataDir,
            extensionsDir: stateDirs.extensionsDir
        )

        state = .starting
        try launchProcess(
            executableURL: executableURL,
            port: port,
            userDataDir: stateDirs.userDataDir,
            extensionsDir: stateDirs.extensionsDir,
            launchDirectory: launchDirectory
        )

        let ready = await waitForServerReady(port: port)
        guard ready else {
            terminateProcess()
            if userStopped || Task.isCancelled {
                throw VSCodeRuntimeError.cancelled
            }
            if process?.isRunning == false {
                throw VSCodeRuntimeError.processExitedBeforeReady
            }
            throw VSCodeRuntimeError.startupTimeout
        }

        if userStopped || Task.isCancelled {
            terminateProcess()
            throw VSCodeRuntimeError.cancelled
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
            throw VSCodeRuntimeError.startupTimeout
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
            throw VSCodeRuntimeError.startupTimeout
        }

        var assignedAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)

        let nameResult = withUnsafeMutablePointer(to: &assignedAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard nameResult == 0 else {
            throw VSCodeRuntimeError.startupTimeout
        }

        return Int(UInt16(bigEndian: assignedAddress.sin_port))
    }

    private func launchProcess(
        executableURL: URL,
        port: Int,
        userDataDir: URL,
        extensionsDir: URL,
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
        process.executableURL = executableURL
        process.currentDirectoryURL = URL(fileURLWithPath: launchDirectory, isDirectory: true)
        process.arguments = [
            "--host", "127.0.0.1",
            "--port", String(port),
            "--auth", "none",
            "--user-data-dir", userDataDir.path,
            "--extensions-dir", extensionsDir.path,
            launchDirectory
        ]

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

    private func ensureRequiredExtensionsInstalled(
        executableURL: URL,
        userDataDir: URL,
        extensionsDir: URL
    ) async {
        guard !requiredExtensionIDs.isEmpty else { return }
        guard !userStopped, !Task.isCancelled else { return }

        let installed: Set<String>
        do {
            installed = try await listInstalledExtensions(
                executableURL: executableURL,
                userDataDir: userDataDir,
                extensionsDir: extensionsDir
            )
        } catch {
            appendRuntimeLog("failed to list installed VS Code extensions: \(error.localizedDescription)")
            return
        }

        let missing = requiredExtensionIDs.filter { id in
            !installed.contains(id.lowercased())
        }
        guard !missing.isEmpty else { return }

        appendRuntimeLog("installing required VS Code extensions: \(missing.joined(separator: ", "))")
        for extensionID in missing {
            guard !userStopped, !Task.isCancelled else { return }
            do {
                let result = try await processRunner.run(
                    executable: executableURL.path,
                    arguments: [
                        "--user-data-dir", userDataDir.path,
                        "--extensions-dir", extensionsDir.path,
                        "--install-extension", extensionID,
                        "--force"
                    ],
                    currentDirectory: nil
                )
                if result.exitCode == 0 {
                    appendRuntimeLog("extension installed: \(extensionID)")
                } else {
                    let details = result.stderr.isEmpty ? result.stdout : result.stderr
                    appendRuntimeLog("extension install failed for \(extensionID): \(details)")
                }
            } catch {
                appendRuntimeLog("extension install error for \(extensionID): \(error.localizedDescription)")
            }
        }
    }

    private func listInstalledExtensions(
        executableURL: URL,
        userDataDir: URL,
        extensionsDir: URL
    ) async throws -> Set<String> {
        let result = try await processRunner.run(
            executable: executableURL.path,
            arguments: [
                "--user-data-dir", userDataDir.path,
                "--extensions-dir", extensionsDir.path,
                "--list-extensions"
            ],
            currentDirectory: nil
        )

        guard result.exitCode == 0 else {
            let details = result.stderr.isEmpty ? result.stdout : result.stderr
            throw VSCodeRuntimeError.commandFailed(
                command: "\(executableURL.path) --list-extensions",
                code: result.exitCode,
                stderr: details
            )
        }

        let ids = result.stdout
            .split(whereSeparator: \.isNewline)
            .map { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            .filter { !$0.isEmpty }
        return Set(ids)
    }

    private func handleProcessExit(_ terminatedProcess: Process) {
        appendRuntimeLog(
            "process exited status=\(terminatedProcess.terminationStatus) reason=\(terminatedProcess.terminationReason.rawValue)"
        )

        terminateProcess()

        guard !userStopped else { return }
        if case .failed = state { return }

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
            Logger.error("Failed writing VS Code runtime log data: \(error.localizedDescription)")
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
                Logger.error("Failed opening VS Code runtime log: \(error.localizedDescription)")
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

    private func loadPersistedZoom() -> CGFloat {
        guard userDefaults.object(forKey: zoomDefaultsKey) != nil else {
            return 1.0
        }

        let stored = CGFloat(userDefaults.double(forKey: zoomDefaultsKey))
        guard stored.isFinite else {
            return 1.0
        }
        return max(minimumZoom, min(maximumZoom, stored))
    }

    private func persistZoom(_ zoom: CGFloat) {
        userDefaults.set(Double(zoom), forKey: zoomDefaultsKey)
    }

    private static func zoomDefaultsKey(for seedPath: String) -> String {
        let expanded = NSString(string: seedPath).expandingTildeInPath
        let canonicalPath = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
        return "idx0.vscode.zoom.\(sha256Hex(canonicalPath))"
    }

    private static func sha256Hex(_ value: String) -> String {
        let data = Data(value.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func isRetryableStartupError(_ error: Error) -> Bool {
        guard let runtimeError = error as? VSCodeRuntimeError else {
            return false
        }

        switch runtimeError {
        case .startupTimeout, .processExitedBeforeReady:
            return true
        case .unsupportedPlatform,
                .invalidDownloadURL,
                .downloadFailed,
                .checksumMismatch,
                .missingExecutable,
                .commandFailed,
                .cancelled:
            return false
        }
    }

    private func logPathForError(_ error: Error) -> String {
        guard let runtimeError = error as? VSCodeRuntimeError else {
            return paths.runtimeLogPath.path
        }

        switch runtimeError {
        case .unsupportedPlatform,
                .invalidDownloadURL,
                .downloadFailed,
                .checksumMismatch,
                .missingExecutable,
                .commandFailed:
            return paths.provisionLogPath.path
        case .startupTimeout,
                .processExitedBeforeReady,
                .cancelled:
            return paths.runtimeLogPath.path
        }
    }
}
