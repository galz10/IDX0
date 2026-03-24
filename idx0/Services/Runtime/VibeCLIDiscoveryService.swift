import Foundation

struct VibeCLIDiscoveryService {
    private let environment: [String: String]
    private let fileManager: FileManager
    private let shellLookup: (String) -> String?
    private let homeDirectory: String

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        shellLookup: ((String) -> String?)? = nil,
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.shellLookup = shellLookup ?? { _ in nil }
        self.homeDirectory = homeDirectory
    }

    func discoverInstalledTools() -> [VibeCLITool] {
        let searchDirectories = pathDirectories()
        return VibeCLITool.known.map { tool in
            var next = tool
            next.resolvedPath = resolveExecutable(for: tool, searchDirectories: searchDirectories)
            next.isInstalled = next.resolvedPath != nil
            return next
        }
    }

    func tool(withID id: String?) -> VibeCLITool? {
        guard let id else { return nil }
        return discoverInstalledTools().first(where: { $0.id == id })
    }

    private func resolveExecutable(for tool: VibeCLITool, searchDirectories: [String]) -> String? {
        for candidate in executableCandidates(for: tool) {
            if let resolved = resolveExecutable(named: candidate, searchDirectories: searchDirectories) {
                return resolved
            }
        }
        return nil
    }

    private func executableCandidates(for tool: VibeCLITool) -> [String] {
        if tool.id == "gemini-cli" {
            return [tool.executableName, "gemini"]
        }
        return [tool.executableName]
    }

    private func resolveExecutable(named executable: String, searchDirectories: [String]) -> String? {
        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent(executable, isDirectory: false)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        if let shellResolved = shellLookup(executable),
           fileManager.isExecutableFile(atPath: shellResolved) {
            return shellResolved
        }

        return nil
    }

    private func pathDirectories() -> [String] {
        var directories: [String] = []
        let envPath = environment["PATH"] ?? ""
        directories.append(contentsOf: envPath.split(separator: ":").map(String.init))
        directories.append(contentsOf: shellPathDirectories())
        directories.append(contentsOf: defaultPathDirectories())

        var seen: Set<String> = []
        var unique: [String] = []
        for directory in directories {
            guard !directory.isEmpty else { continue }
            if seen.insert(directory).inserted {
                unique.append(directory)
            }
        }
        return unique
    }

    private func defaultPathDirectories() -> [String] {
        let home = homeDirectory
        var directories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "\(home)/.asdf/shims",
            "\(home)/.volta/bin",
            "\(home)/.cargo/bin",
            "\(home)/.local/bin",
            "\(home)/bin",
            "\(home)/.bun/bin",
            "\(home)/Library/pnpm",
            "\(home)/.npm-global/bin",
            "\(home)/.yarn/bin",
            "\(home)/.config/yarn/global/node_modules/.bin",
            "\(home)/.nvm/versions/node/current/bin"
        ]
        directories.append(contentsOf: nvmVersionBinDirectories(home: home))
        return directories
    }

    private func nvmVersionBinDirectories(home: String) -> [String] {
        let root = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".nvm/versions/node", isDirectory: true)
        guard let versions = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return versions
            .filter { url in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            .map { $0.appendingPathComponent("bin", isDirectory: true).path }
            .filter { directory in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: directory, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            .sorted { lhs, rhs in
                lhs.localizedStandardCompare(rhs) == .orderedDescending
            }
    }

    private func shellPathDirectories() -> [String] {
        var directories: [String] = []
        if let loginPath = Self.pathFromZsh(argumentFlag: "-lc", environment: environment) {
            directories.append(contentsOf: loginPath.split(separator: ":").map(String.init))
        }
        if let interactivePath = Self.pathFromZsh(argumentFlag: "-ilc", environment: environment) {
            directories.append(contentsOf: interactivePath.split(separator: ":").map(String.init))
        }
        return directories
    }

    private static func pathFromZsh(argumentFlag: String, environment: [String: String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [argumentFlag, "printf '%s' \"$PATH\""]
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return nil }
        return output
    }
}
