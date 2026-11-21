import Darwin
import Foundation

enum ConnectorError: LocalizedError {
    case setup(String)

    var errorDescription: String? {
        switch self {
        case let .setup(message): return message
        }
    }
}

enum ConnectorSetup {
    enum Client: String {
        case desktop = "claude-desktop"
        case claude = "claude-code"
        case codex
        case kimi = "kimi-code"

        var name: String {
            switch self {
            case .desktop: return "Claude Desktop"
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            case .kimi: return "Kimi Code"
            }
        }
    }

    static func command(_ arguments: [String]) throws {
        guard let first = arguments.first, let client = Client(rawValue: first),
              arguments.count == 1 || (arguments.count == 2 && [.claude, .codex].contains(client)) else {
            throw ConnectorError.setup("Use hereforth connect claude-desktop, claude-code, codex, or kimi-code.")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            throw ConnectorError.setup("Couldn’t locate the Hereforth helper.")
        }
        let macOS = executable.deletingLastPathComponent()
        let app = macOS.deletingLastPathComponent().deletingLastPathComponent()
        let installedIn = app.deletingLastPathComponent().resolvingSymlinksInPath()
        let locations = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        guard macOS.lastPathComponent == "MacOS", app.pathExtension == "app",
              Bundle(url: app)?.bundleIdentifier == "com.hereforth.app",
              locations.contains(where: { $0.resolvingSymlinksInPath().path == installedIn.path }) else {
            throw ConnectorError.setup("Move Hereforth to Applications or your home Applications folder, then reopen it.")
        }
        let selectedExecutable = arguments.count == 2 ? URL(fileURLWithPath: arguments[1]) : nil
        try connect(client, helper: executable.path, home: home, selectedExecutable: selectedExecutable)
    }

    static func connect(_ client: Client, helper: String, home: URL, selectedExecutable: URL? = nil) throws {
        var environment = ProcessInfo.processInfo.environment
        let paths = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":")
            .filter { $0.hasPrefix("/") }.map(String.init) + [
                home.appendingPathComponent(".local/bin").path,
                home.appendingPathComponent("bin").path,
                "/opt/homebrew/bin", "/usr/local/bin",
                "/Applications/Codex.app/Contents/Resources",
                home.appendingPathComponent("Applications/Codex.app/Contents/Resources").path,
                "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS",
                home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS").path
            ]
        environment["PATH"] = paths.joined(separator: ":")

        switch client {
        case .desktop:
            let directory = home.appendingPathComponent("Library/Application Support/Claude")
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ConnectorError.setup("Open Claude Desktop once to initialize its settings, then connect it here.")
            }
            let config = directory.appendingPathComponent("claude_desktop_config.json").resolvingSymlinksInPath()
            try registerJSONFile(client, config: config, helper: helper)
        case .claude:
            let directory = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home
            let config = directory.appendingPathComponent(".claude.json")
            try registerJSON(client, config: config.resolvingSymlinksInPath(), helper: helper) { _, _ in
                let executable = try findExecutable("claude", client: client, selected: selectedExecutable, paths: paths)
                let status = try run(executable, ["mcp", "add", "--scope", "user", "--transport", "stdio",
                                                  "hereforth", "--", helper, "mcp"], environment: environment)
                guard status.0 == 0 else {
                    throw ConnectorError.setup("Claude Code couldn’t register Hereforth. Check its MCP settings.")
                }
            }
        case .codex:
            let executable = try findExecutable("codex", client: client, selected: selectedExecutable, paths: paths)
            let (status, data) = try run(executable, ["mcp", "get", "hereforth", "--json"], environment: environment)
            if status == 0 {
                guard let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let transport = entry["transport"] as? [String: Any],
                      transport["type"] as? String == "stdio",
                      transport["command"] as? String == helper, transport["args"] as? [String] == ["mcp"]
                else { throw conflict(client) }
                print("Hereforth is already connected to Codex.")
                return
            }
            let missing = "No MCP server named 'hereforth' found."
            guard String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).contains(where: {
                $0 == missing || $0 == "Error: " + missing
            }) else { throw ConnectorError.setup("Codex couldn’t read its MCP configuration.") }
            let (added, _) = try run(executable, ["mcp", "add", "hereforth", "--", helper, "mcp"], environment: environment)
            guard added == 0 else { throw ConnectorError.setup("Codex couldn’t register Hereforth. Check its MCP settings.") }
            print("Connected Hereforth to Codex.")
        case .kimi:
            let directory = environment["KIMI_CODE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                ?? home.appendingPathComponent(".kimi-code", isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ConnectorError.setup("Open the current Kimi Code once to initialize its profile, then connect it here.")
            }
            let config = directory.appendingPathComponent("mcp.json")
            try registerJSONFile(client, config: config, helper: helper)
        }
    }

    private static func registerJSONFile(_ client: Client, config: URL, helper: String) throws {
        try registerJSON(client, config: config, helper: helper) { settings, existing in
            let data = try JSONSerialization.data(withJSONObject: settings,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            guard try readConfig(config) == existing else {
                throw ConnectorError.setup("\(client.name)’s configuration changed. Try connecting again.")
            }
            let oldMask = umask(0o077)
            defer { _ = umask(oldMask) }
            try data.write(to: config, options: .atomic)
        }
    }

    private static func registerJSON(_ client: Client, config: URL, helper: String,
                                     write: ([String: Any], Data?) throws -> Void) throws {
        let data = try readConfig(config)
        var settings: [String: Any] = [:]
        if let data {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ConnectorError.setup("\(client.name)’s configuration must contain valid JSON.")
            }
            settings = parsed
        }
        var servers: [String: Any] = [:]
        if let existing = settings["mcpServers"] {
            guard let parsed = existing as? [String: Any] else {
                throw ConnectorError.setup("\(client.name)’s MCP server settings have an unexpected format.")
            }
            servers = parsed
        }
        if let existing = servers["hereforth"] {
            guard let entry = existing as? [String: Any], entry["command"] as? String == helper,
                  entry["args"] as? [String] == ["mcp"], entry["type"] == nil || entry["type"] as? String == "stdio",
                  entry["env"] == nil || (entry["env"] as? [String: Any])?.isEmpty == true
            else { throw conflict(client) }
            if client == .kimi {
                guard entry["transport"] == nil || entry["transport"] as? String == "stdio",
                      entry["environment_id"] == nil || entry["environment_id"] as? String == "local",
                      entry["enabled"] == nil || entry["enabled"] as? Bool == true,
                      entry["url"] == nil else { throw conflict(client) }
            }
            print("Hereforth is already connected to \(client.name).")
            return
        }

        servers["hereforth"] = ["command": helper, "args": ["mcp"]]
        settings["mcpServers"] = servers
        try write(settings, data)
        print("Connected Hereforth to \(client.name).")
    }

    private static func readConfig(_ url: URL) throws -> Data? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw ConnectorError.setup("The assistant configuration must be a regular file.")
            }
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch CocoaError.fileNoSuchFile {
            return nil
        }
    }

    private static func findExecutable(_ name: String, client: Client, selected: URL?, paths: [String]) throws -> URL {
        let candidates = selected.map { [$0] } ?? paths.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
        if let executable = candidates.first(where: { candidate in
            FileManager.default.isExecutableFile(atPath: candidate.path)
                && (try? candidate.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }) {
            return executable
        }
        throw ConnectorError.setup("Couldn’t locate the \(client.name) CLI. Install it or choose its executable.")
    }

    private static func run(_ executable: URL, _ arguments: [String],
                            environment: [String: String]) throws -> (Int32, Data) {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    private static func conflict(_ client: Client) -> ConnectorError {
        .setup("\(client.name) already has a different server named hereforth. Its configuration was left unchanged.")
    }
}
