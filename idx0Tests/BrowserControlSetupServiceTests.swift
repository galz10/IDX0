import Foundation
import XCTest
@testable import idx0

final class BrowserControlSetupServiceTests: XCTestCase {
    func testProvisionInstallsWrapperAndConfiguresSupportedInstalledCLIs() async throws {
        let appSupport = temporaryAppSupportRoot()
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let runner = RecordingProcessRunner { executable, arguments, _ in
            if executable == "/usr/bin/env", arguments.first == "npm" {
                if let prefixIndex = arguments.firstIndex(of: "--prefix"),
                   arguments.indices.contains(prefixIndex + 1) {
                    let installRoot = URL(fileURLWithPath: arguments[prefixIndex + 1], isDirectory: true)
                    let binaryURL = installRoot
                        .appendingPathComponent("node_modules", isDirectory: true)
                        .appendingPathComponent(".bin", isDirectory: true)
                        .appendingPathComponent("playwright-mcp", isDirectory: false)
                    try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try "#!/bin/sh\nexit 0\n".write(to: binaryURL, atomically: true, encoding: .utf8)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
                }
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }

        let discoveredTools = [
            VibeCLITool(id: "codex", displayName: "Codex", executableName: "codex", launchCommand: "codex", isInstalled: true, resolvedPath: "/usr/local/bin/codex"),
            VibeCLITool(id: "claude", displayName: "Claude", executableName: "claude", launchCommand: "claude", isInstalled: true, resolvedPath: "/usr/local/bin/claude"),
            VibeCLITool(id: "gemini-cli", displayName: "Gemini", executableName: "gemini", launchCommand: "gemini", isInstalled: true, resolvedPath: "/usr/local/bin/gemini"),
        ]

        let service = BrowserControlSetupService(
            appSupportDirectory: appSupport,
            processRunner: runner,
            discoveredToolsProvider: { discoveredTools }
        )

        let result = try await service.provision(force: false, preferredBrowserAppURL: nil)

        XCTAssertEqual(result.serverName, BrowserControlSetupService.mcpServerName)
        XCTAssertEqual(result.configuredToolIDs, ["claude", "codex", "gemini-cli"])
        XCTAssertTrue(result.skippedToolIDs.isEmpty)
        XCTAssertEqual(result.wrapperCommand, [result.wrapperScriptPath])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: result.wrapperScriptPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.chromiumProfilePath))

        let commands = await runner.recordedInvocations()
        XCTAssertTrue(commands.contains {
            $0.executable == "/usr/local/bin/codex" &&
                $0.arguments == ["mcp", "add", "idx0-browser", "--", result.wrapperScriptPath]
        })
        XCTAssertTrue(commands.contains {
            $0.executable == "/usr/local/bin/claude" &&
                $0.arguments == ["mcp", "add", "--scope", "user", "idx0-browser", "--", result.wrapperScriptPath]
        })
        XCTAssertTrue(commands.contains {
            $0.executable == "/usr/local/bin/gemini" &&
                $0.arguments == ["mcp", "add", "--scope", "user", "idx0-browser", result.wrapperScriptPath]
        })
    }

    func testProvisionIsIdempotentWhenManifestAndArtifactsExist() async throws {
        let appSupport = temporaryAppSupportRoot()
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let runner = RecordingProcessRunner { executable, arguments, _ in
            if executable == "/usr/bin/env", arguments.first == "npm" {
                if let prefixIndex = arguments.firstIndex(of: "--prefix"),
                   arguments.indices.contains(prefixIndex + 1) {
                    let installRoot = URL(fileURLWithPath: arguments[prefixIndex + 1], isDirectory: true)
                    let binaryURL = installRoot
                        .appendingPathComponent("node_modules", isDirectory: true)
                        .appendingPathComponent(".bin", isDirectory: true)
                        .appendingPathComponent("playwright-mcp", isDirectory: false)
                    try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try "#!/bin/sh\nexit 0\n".write(to: binaryURL, atomically: true, encoding: .utf8)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
                }
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }

        let discoveredTools = [
            VibeCLITool(id: "codex", displayName: "Codex", executableName: "codex", launchCommand: "codex", isInstalled: true, resolvedPath: "/usr/local/bin/codex"),
        ]

        let service = BrowserControlSetupService(
            appSupportDirectory: appSupport,
            processRunner: runner,
            discoveredToolsProvider: { discoveredTools }
        )

        _ = try await service.provision(force: false, preferredBrowserAppURL: nil)
        let firstCommandCount = await runner.recordedInvocations().count
        XCTAssertGreaterThan(firstCommandCount, 0)

        _ = try await service.provision(force: false, preferredBrowserAppURL: nil)
        let secondCommandCount = await runner.recordedInvocations().count

        XCTAssertEqual(secondCommandCount, firstCommandCount)
    }

    func testProvisionFailsWhenInstalledCLIConfigFails() async throws {
        let appSupport = temporaryAppSupportRoot()
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let runner = RecordingProcessRunner { executable, arguments, _ in
            if executable == "/usr/bin/env", arguments.first == "npm" {
                if let prefixIndex = arguments.firstIndex(of: "--prefix"),
                   arguments.indices.contains(prefixIndex + 1) {
                    let installRoot = URL(fileURLWithPath: arguments[prefixIndex + 1], isDirectory: true)
                    let binaryURL = installRoot
                        .appendingPathComponent("node_modules", isDirectory: true)
                        .appendingPathComponent(".bin", isDirectory: true)
                        .appendingPathComponent("playwright-mcp", isDirectory: false)
                    try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try "#!/bin/sh\nexit 0\n".write(to: binaryURL, atomically: true, encoding: .utf8)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
                }
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
            if executable == "/usr/local/bin/codex",
               arguments.prefix(3).elementsEqual(["mcp", "add", "idx0-browser"]) {
                return ProcessResult(exitCode: 1, stdout: "", stderr: "failed to write config")
            }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }

        let discoveredTools = [
            VibeCLITool(id: "codex", displayName: "Codex", executableName: "codex", launchCommand: "codex", isInstalled: true, resolvedPath: "/usr/local/bin/codex"),
        ]

        let service = BrowserControlSetupService(
            appSupportDirectory: appSupport,
            processRunner: runner,
            discoveredToolsProvider: { discoveredTools }
        )

        do {
            _ = try await service.provision(force: false, preferredBrowserAppURL: nil)
            XCTFail("Expected CLI configuration failure")
        } catch let error as BrowserControlSetupError {
            guard case .cliConfigurationFailed(let toolID, _, _) = error else {
                XCTFail("Unexpected setup error: \(error)")
                return
            }
            XCTAssertEqual(toolID, "codex")
        }
    }

    private func temporaryAppSupportRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx0-browser-control-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private actor RecordingProcessRunner: ProcessRunnerProtocol {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
        let currentDirectory: String?
    }

    private let handler: @Sendable (String, [String], String?) async throws -> ProcessResult
    private var invocations: [Invocation] = []

    init(handler: @escaping @Sendable (String, [String], String?) async throws -> ProcessResult) {
        self.handler = handler
    }

    func run(executable: String, arguments: [String], currentDirectory: String?) async throws -> ProcessResult {
        invocations.append(
            Invocation(
                executable: executable,
                arguments: arguments,
                currentDirectory: currentDirectory
            )
        )
        return try await handler(executable, arguments, currentDirectory)
    }

    func recordedInvocations() -> [Invocation] {
        invocations
    }
}
