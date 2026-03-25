import Foundation

protocol BrowserControlSetupServicing: Sendable {
    func provision(force: Bool, preferredBrowserAppURL: URL?) async throws -> BrowserControlSetupResult
}

struct BrowserControlSetupResult: Equatable, Sendable {
    let serverName: String
    let wrapperCommand: [String]
    let wrapperScriptPath: String
    let chromiumProfilePath: String
    let browserExecutablePath: String?
    let configuredToolIDs: [String]
    let skippedToolIDs: [String]
}

enum BrowserControlSetupError: LocalizedError {
    case npmInstallFailed(command: String, output: String)
    case playwrightMCPBinaryMissing(String)
    case wrapperWriteFailed(String)
    case cliConfigurationFailed(toolID: String, command: String, output: String)

    var errorDescription: String? {
        switch self {
        case .npmInstallFailed(let command, let output):
            return "Browser control install failed while running `\(command)`: \(output)"
        case .playwrightMCPBinaryMissing(let path):
            return "Browser control install completed but Playwright MCP binary was not found at \(path)."
        case .wrapperWriteFailed(let message):
            return "Failed to write browser control launch wrapper: \(message)"
        case .cliConfigurationFailed(let toolID, let command, let output):
            return "Configured \(toolID), but MCP registration failed (`\(command)`): \(output)"
        }
    }
}

private struct BrowserControlSetupManifest: Codable {
    let version: Int
    let playwrightPackage: String
    let browserExecutablePath: String?
    let configuredToolIDs: [String]
    let skippedToolIDs: [String]
    let updatedAt: Date
}

actor BrowserControlSetupService: BrowserControlSetupServicing {
    static let mcpServerName = "idx0-browser"
    static let pinnedPlaywrightMCPPackage = "@playwright/mcp@0.0.68"
    static let manifestVersion = 1
    static let wrapperScriptName = "idx0-browser-mcp"

    private let appSupportDirectory: URL
    private let processRunner: any ProcessRunnerProtocol
    private let fileManager: FileManager
    private let discoveredToolsProvider: () -> [VibeCLITool]

    init(
        appSupportDirectory: URL,
        processRunner: any ProcessRunnerProtocol = ProcessRunner(),
        fileManager: FileManager = .default,
        discoveredToolsProvider: @escaping () -> [VibeCLITool] = {
            VibeCLIDiscoveryService().discoverInstalledTools()
        }
    ) {
        self.appSupportDirectory = appSupportDirectory
        self.processRunner = processRunner
        self.fileManager = fileManager
        self.discoveredToolsProvider = discoveredToolsProvider
    }

    static func installRootURL(appSupportDirectory: URL) -> URL {
        appSupportDirectory.appendingPathComponent("browser-control", isDirectory: true)
    }

    static func wrapperScriptURL(appSupportDirectory: URL) -> URL {
        installRootURL(appSupportDirectory: appSupportDirectory)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(wrapperScriptName, isDirectory: false)
    }

    static func chromiumProfileDirectoryURL(appSupportDirectory: URL) -> URL {
        installRootURL(appSupportDirectory: appSupportDirectory)
            .appendingPathComponent("chromium-profile", isDirectory: true)
    }

    private static func manifestURL(appSupportDirectory: URL) -> URL {
        installRootURL(appSupportDirectory: appSupportDirectory)
            .appendingPathComponent("manifest.json", isDirectory: false)
    }

    func provision(force: Bool, preferredBrowserAppURL: URL?) async throws -> BrowserControlSetupResult {
        let installRootURL = Self.installRootURL(appSupportDirectory: appSupportDirectory)
        let wrapperScriptURL = Self.wrapperScriptURL(appSupportDirectory: appSupportDirectory)
        let chromiumProfileDirectoryURL = Self.chromiumProfileDirectoryURL(appSupportDirectory: appSupportDirectory)
        let manifestURL = Self.manifestURL(appSupportDirectory: appSupportDirectory)
        let playwrightMCPBinaryURL = installRootURL
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(".bin", isDirectory: true)
            .appendingPathComponent("playwright-mcp", isDirectory: false)

        if !force,
           let manifest = loadManifest(at: manifestURL),
           manifest.version == Self.manifestVersion,
           manifest.playwrightPackage == Self.pinnedPlaywrightMCPPackage,
           fileManager.isExecutableFile(atPath: wrapperScriptURL.path),
           fileManager.isExecutableFile(atPath: playwrightMCPBinaryURL.path),
           fileManager.fileExists(atPath: chromiumProfileDirectoryURL.path) {
            return BrowserControlSetupResult(
                serverName: Self.mcpServerName,
                wrapperCommand: [wrapperScriptURL.path],
                wrapperScriptPath: wrapperScriptURL.path,
                chromiumProfilePath: chromiumProfileDirectoryURL.path,
                browserExecutablePath: manifest.browserExecutablePath,
                configuredToolIDs: manifest.configuredToolIDs,
                skippedToolIDs: manifest.skippedToolIDs
            )
        }

        try fileManager.createDirectory(at: installRootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: wrapperScriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: chromiumProfileDirectoryURL, withIntermediateDirectories: true)

        try await installPlaywrightMCP(to: installRootURL)

        guard fileManager.isExecutableFile(atPath: playwrightMCPBinaryURL.path) else {
            throw BrowserControlSetupError.playwrightMCPBinaryMissing(playwrightMCPBinaryURL.path)
        }

        let browserExecutablePath = resolveChromiumExecutablePath(appBundleURL: preferredBrowserAppURL)
        try writeWrapperScript(
            wrapperScriptURL: wrapperScriptURL,
            mcpBinaryURL: playwrightMCPBinaryURL,
            chromiumProfileDirectoryURL: chromiumProfileDirectoryURL,
            browserExecutablePath: browserExecutablePath
        )

        let (configuredToolIDs, skippedToolIDs) = try await configureSupportedCLIs(wrapperScriptURL: wrapperScriptURL)

        let manifest = BrowserControlSetupManifest(
            version: Self.manifestVersion,
            playwrightPackage: Self.pinnedPlaywrightMCPPackage,
            browserExecutablePath: browserExecutablePath,
            configuredToolIDs: configuredToolIDs,
            skippedToolIDs: skippedToolIDs,
            updatedAt: Date()
        )
        let manifestData = try JSONEncoder.prettyPrintedSorted().encode(manifest)
        try manifestData.write(to: manifestURL, options: .atomic)

        return BrowserControlSetupResult(
            serverName: Self.mcpServerName,
            wrapperCommand: [wrapperScriptURL.path],
            wrapperScriptPath: wrapperScriptURL.path,
            chromiumProfilePath: chromiumProfileDirectoryURL.path,
            browserExecutablePath: browserExecutablePath,
            configuredToolIDs: configuredToolIDs,
            skippedToolIDs: skippedToolIDs
        )
    }

    private func installPlaywrightMCP(to installRootURL: URL) async throws {
        let installArguments = [
            "npm",
            "install",
            "--prefix", installRootURL.path,
            "--no-audit",
            "--no-fund",
            "--loglevel", "error",
            Self.pinnedPlaywrightMCPPackage,
        ]
        let result = try await processRunner.run(
            executable: "/usr/bin/env",
            arguments: installArguments,
            currentDirectory: nil
        )
        guard result.exitCode == 0 else {
            throw BrowserControlSetupError.npmInstallFailed(
                command: (["/usr/bin/env"] + installArguments).joined(separator: " "),
                output: combinedOutput(stdout: result.stdout, stderr: result.stderr)
            )
        }
    }

    private func writeWrapperScript(
        wrapperScriptURL: URL,
        mcpBinaryURL: URL,
        chromiumProfileDirectoryURL: URL,
        browserExecutablePath: String?
    ) throws {
        let browserValue = browserExecutablePath ?? ""
        let script = """
        #!/bin/bash
        set -euo pipefail

        MCP_BIN=\(shellQuote(mcpBinaryURL.path))
        PROFILE_DIR=\(shellQuote(chromiumProfileDirectoryURL.path))
        BROWSER_EXECUTABLE=\(shellQuote(browserValue))

        DEFAULT_ARGS=("--user-data-dir=${PROFILE_DIR}")
        if [[ -n "${BROWSER_EXECUTABLE}" ]]; then
          DEFAULT_ARGS+=("--browser=chrome" "--executable-path=${BROWSER_EXECUTABLE}")
        fi

        exec "${MCP_BIN}" "${DEFAULT_ARGS[@]}" "$@"
        """

        do {
            try script.write(to: wrapperScriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: wrapperScriptURL.path
            )
        } catch {
            throw BrowserControlSetupError.wrapperWriteFailed(error.localizedDescription)
        }
    }

    private func configureSupportedCLIs(wrapperScriptURL: URL) async throws -> (configured: [String], skipped: [String]) {
        let discoveredByID = Dictionary(
            uniqueKeysWithValues: discoveredToolsProvider().map { ($0.id, $0) }
        )

        var configured: [String] = []
        var skipped: [String] = []

        for toolID in ["codex", "claude", "gemini-cli"] {
            guard let tool = discoveredByID[toolID],
                  tool.isInstalled,
                  let executablePath = tool.resolvedPath else {
                skipped.append(toolID)
                continue
            }

            let removeArguments = mcpRemoveArguments(for: toolID, serverName: Self.mcpServerName)
            let removeResult = try await processRunner.run(
                executable: executablePath,
                arguments: removeArguments,
                currentDirectory: nil
            )
            _ = removeResult

            let addArguments = mcpAddArguments(
                for: toolID,
                serverName: Self.mcpServerName,
                wrapperScriptPath: wrapperScriptURL.path
            )
            let addResult = try await processRunner.run(
                executable: executablePath,
                arguments: addArguments,
                currentDirectory: nil
            )
            guard addResult.exitCode == 0 else {
                throw BrowserControlSetupError.cliConfigurationFailed(
                    toolID: toolID,
                    command: ([executablePath] + addArguments).joined(separator: " "),
                    output: combinedOutput(stdout: addResult.stdout, stderr: addResult.stderr)
                )
            }
            configured.append(toolID)
        }

        return (configured.sorted(), skipped.sorted())
    }

    private func loadManifest(at url: URL) -> BrowserControlSetupManifest? {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(BrowserControlSetupManifest.self, from: data)
    }

    private func resolveChromiumExecutablePath(appBundleURL: URL?) -> String? {
        guard let appBundleURL else { return nil }
        let macOSDirectoryURL = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: macOSDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for candidate in candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }

    private func shellQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    private func combinedOutput(stdout: String, stderr: String) -> String {
        let merged = [stderr.trimmingCharacters(in: .whitespacesAndNewlines), stdout.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return merged.isEmpty ? "No command output." : merged
    }

    private func mcpRemoveArguments(for toolID: String, serverName: String) -> [String] {
        switch toolID {
        case "codex":
            return ["mcp", "remove", serverName]
        case "claude":
            return ["mcp", "remove", "--scope", "user", serverName]
        case "gemini-cli":
            return ["mcp", "remove", "--scope", "user", serverName]
        default:
            return ["mcp", "remove", serverName]
        }
    }

    private func mcpAddArguments(for toolID: String, serverName: String, wrapperScriptPath: String) -> [String] {
        switch toolID {
        case "codex":
            return ["mcp", "add", serverName, "--", wrapperScriptPath]
        case "claude":
            return ["mcp", "add", "--scope", "user", serverName, "--", wrapperScriptPath]
        case "gemini-cli":
            return ["mcp", "add", "--scope", "user", serverName, wrapperScriptPath]
        default:
            return ["mcp", "add", serverName, wrapperScriptPath]
        }
    }
}

private extension JSONEncoder {
    static func prettyPrintedSorted() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
