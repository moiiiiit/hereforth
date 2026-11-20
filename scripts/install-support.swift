import Darwin
import Foundation

private enum InstallationError: Error {
    case unexpectedBundle
    case configInvalid
    case serverConflict
    case claudeFailed
}

private func installBundle(from staging: String, at destination: String) throws {
    let source = URL(fileURLWithPath: staging)
    let target = URL(fileURLWithPath: destination)
    let files = FileManager.default
    do {
        // RENAME_EXCL also refuses a destination that appeared during the build.
        let result = renamex_np(source.path, target.path, UInt32(RENAME_EXCL))
        if result == 0 { return }
        guard errno == EEXIST,
              try target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false,
              files.fileExists(atPath: target.appendingPathComponent("Contents/Resources/hereforth-install").path),
              Bundle(url: target)?.bundleIdentifier == "com.hereforth.app"
        else { throw InstallationError.unexpectedBundle }

        guard renamex_np(source.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
            throw InstallationError.unexpectedBundle
        }
    } catch {
        throw InstallationError.unexpectedBundle
    }
}

private func register(client: String, path: String, helper: String, claude: String?) throws {
    let config = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    var data: Data?
    do {
        data = try Data(contentsOf: config)
    } catch CocoaError.fileReadNoSuchFile {
        data = nil
    }

    var settings: [String: Any] = [:]
    if let data {
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallationError.configInvalid
        }
        settings = parsed
    }
    var servers: [String: Any] = [:]
    if let existing = settings["mcpServers"] {
        guard let parsed = existing as? [String: Any] else {
            throw InstallationError.configInvalid
        }
        servers = parsed
    }
    if let existing = servers["hereforth"] {
        guard let entry = existing as? [String: Any],
              entry["command"] as? String == helper,
              entry["args"] as? [String] == ["mcp"],
              entry["type"] == nil || entry["type"] as? String == "stdio",
              entry["env"] == nil || (entry["env"] as? [String: Any])?.isEmpty == true
        else { throw InstallationError.serverConflict }
        print("Hereforth is already registered with \(client).")
        return
    }

    if let claude {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["mcp", "add", "--scope", "user", "--transport", "stdio", "hereforth", "--", helper, "mcp"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw InstallationError.claudeFailed }
    } else {
        servers["hereforth"] = ["command": helper, "args": ["mcp"]]
        settings["mcpServers"] = servers
        let updated = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        // Keep credentials in a newly created config private.
        _ = umask(0o077)
        try updated.write(to: config, options: .atomic)
    }
    print("Registered Hereforth with \(client).")
}

let args = CommandLine.arguments
let client = args[1] == "code" ? "Claude Code" : "Claude Desktop"
do {
    if args[1] == "bundle" {
        try installBundle(from: args[2], at: args[3])
    } else {
        try register(client: client, path: args[2], helper: args[3], claude: args.count == 5 ? args[4] : nil)
    }
} catch {
    let message: String
    switch error {
    case InstallationError.unexpectedBundle:
        message = "Couldn’t install the app. Check that ~/Applications is writable and Hereforth.app belongs to this installer."
    case InstallationError.serverConflict:
        message = "\(client) already has a different server named hereforth. Its configuration was left unchanged."
    case InstallationError.claudeFailed:
        message = "Claude Code could not register Hereforth. Check your Claude Code MCP settings."
    default:
        message = "Couldn’t update the \(client) configuration. Check that it contains valid JSON and is writable."
    }
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
