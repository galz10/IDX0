import Foundation

enum VibeCLILaunchError: LocalizedError {
    case toolUnavailable(String)
    case sessionUnavailable

    var errorDescription: String? {
        switch self {
        case .toolUnavailable(let toolID):
            return "Tool '\(toolID)' is not installed or not on PATH."
        case .sessionUnavailable:
            return "Session unavailable for tool launch."
        }
    }
}

@MainActor
struct VibeCLILaunchService {
    private let discoveryService = VibeCLIDiscoveryService()
    var shellPool: ShellPoolService?

    func launch(toolID: String, in sessionID: UUID, sessionService: SessionService) throws {
        let tool: VibeCLITool?
        if let pool = shellPool {
            tool = pool.tool(withID: toolID)
        } else {
            tool = discoveryService.tool(withID: toolID)
        }
        guard let tool, tool.isInstalled else {
            throw VibeCLILaunchError.toolUnavailable(toolID)
        }

        guard let controller = sessionService.ensureController(for: sessionID) else {
            throw VibeCLILaunchError.sessionUnavailable
        }

        _ = sessionService.requestLaunch(for: sessionID, reason: .explicitAction)
        let command = launchCommand(for: tool)
        func submitCommand() {
            controller.send(text: command)
            controller.sendReturnKey()
        }
        if case .running = controller.runtimeState {
            submitCommand()
        } else {
            // Launch asynchronously and inject once the shell is likely ready.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                submitCommand()
            }
        }
    }

    private func launchCommand(for tool: VibeCLITool) -> String {
        if let resolvedPath = tool.resolvedPath, !resolvedPath.isEmpty {
            return shellEscape(resolvedPath)
        }
        return tool.launchCommand
    }

    private func shellEscape(_ value: String) -> String {
        if value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
           !value.contains("'") {
            return value
        }
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }
}
