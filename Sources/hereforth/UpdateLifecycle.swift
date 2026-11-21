import Darwin
import Foundation
import HereforthCore

enum UpdateLifecycle {
    static func command(_ operation: String) throws {
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
        guard let appURL = executable?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
              let bundle = Bundle(url: appURL), bundle.bundleIdentifier == "com.hereforth.app",
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else {
            throw HereforthError("Use the updater bundled with the installed Hereforth app.")
        }
        let channel = bundle.object(forInfoDictionaryKey: "HereforthUpdateChannel") as? String
        if channel == "binary" {
            if operation == "status" {
                let track = bundle.object(forInfoDictionaryKey: "HereforthBinaryUpdateTrack") as? String ?? "binary"
                let release = bundle.object(forInfoDictionaryKey: "HereforthReleaseVersion") as? String ?? version
                print("Hereforth \(release) (\(track))")
                print("Manage updates in Hereforth’s app menu and Settings.")
                return
            }
            throw HereforthError("Open Hereforth → Check for Updates or manage automatic checks in Hereforth Settings.")
        }
        guard let script = bundle.url(forResource: "update", withExtension: "sh") else {
            throw HereforthError("Use the updater bundled with the installed Hereforth app.")
        }
        let stable = channel == "stable"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let agent = UpdateAgent(home: home, script: script, stable: stable, domain: "gui/\(getuid())") { arguments in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        switch operation {
        case "check", "install":
            let process = Process()
            process.executableURL = script
            process.arguments = [operation]
            process.standardInput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { exit(1) }
        case "status":
            let enabled = try stable && agent.preference() == true
            print("Hereforth \(version) (\(stable ? "stable" : "development"))")
            print("Automatic updates: \(enabled ? "on, daily at 10:00 a.m. local time" : "off")")
        case "enable", "disable", "configure":
            let installed = home.appendingPathComponent("Applications/Hereforth.app").resolvingSymlinksInPath()
            guard appURL.standardizedFileURL.path == installed.standardizedFileURL.path else {
                throw HereforthError("Manage daily updates from ~/Applications/Hereforth.app.")
            }
            let choice: Bool? = operation == "configure" ? nil : operation == "enable"
            print(try agent.apply(choice: choice))
        default:
            throw HereforthError("Use hereforth update status, check, install, enable, or disable.")
        }
    }
}

struct UpdateAgent {
    private static let label = "com.hereforth.updates"
    let home: URL
    let script: URL
    let stable: Bool
    let domain: String
    let launchctl: ([String]) throws -> Bool

    private var preferenceFile: URL {
        home.appendingPathComponent("Library/Application Support/Hereforth/automatic-updates")
    }

    private var plist: URL {
        home.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
    }

    private var program: [String] { [script.path, "automatic"] }
    private var service: String { "\(domain)/\(Self.label)" }

    func preference() throws -> Bool? {
        do {
            let values = try preferenceFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink == false else {
                throw HereforthError("The automatic update preference is invalid.")
            }
            let value = try String(contentsOf: preferenceFile, encoding: .utf8)
            switch value {
            case "enabled\n": return true
            case "disabled\n": return false
            default: throw HereforthError("The automatic update preference is invalid.")
            }
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch CocoaError.fileNoSuchFile {
            return nil
        }
    }

    func apply(choice: Bool?) throws -> String {
        if choice == true && !stable {
            throw HereforthError("Automatic updates require a signed stable release.")
        }
        let files = FileManager.default
        let previous = try preference()
        let existing = try existingAgent()
        let enabled = stable && (choice ?? previous ?? true)
        if let saved = choice ?? (stable && previous == nil ? true : nil), saved != previous {
            try files.createDirectory(at: preferenceFile.deletingLastPathComponent(),
                                      withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            try (saved ? "enabled\n" : "disabled\n").write(to: preferenceFile, atomically: true, encoding: .utf8)
        }

        if enabled {
            let propertyList: [String: Any] = [
                "Label": Self.label,
                "ProgramArguments": program,
                "StartCalendarInterval": ["Hour": 10, "Minute": 0],
                "StandardErrorPath": home.appendingPathComponent("Library/Logs/Hereforth-updates.log").path,
                "AssociatedBundleIdentifiers": ["com.hereforth.app"],
                "ProcessType": "Background"
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
            let changed = data != existing
            if changed {
                try files.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.createDirectory(at: home.appendingPathComponent("Library/Logs"), withIntermediateDirectories: true)
                try data.write(to: plist, options: .atomic)
            }
            guard try launchctl(["print", domain]) else {
                return "Automatic updates are enabled and will start at the next Mac login."
            }
            let loaded = try launchctl(["print", service])
            if loaded && changed {
                guard try launchctl(["bootout", service]) else {
                    throw HereforthError("The update schedule couldn’t be reloaded. Try again after signing in to macOS.")
                }
            }
            if changed || !loaded {
                guard try launchctl(["bootstrap", domain, plist.path]) else {
                    throw HereforthError("The update schedule is saved. Enable Hereforth in System Settings under Login Items if macOS is blocking it.")
                }
            }
            return "Automatic updates are enabled daily at 10:00 a.m. local time."
        }

        if existing != nil { try files.removeItem(at: plist) }
        if existing != nil || choice == false {
            if try launchctl(["print", service]), try !launchctl(["bootout", service]) {
                throw HereforthError("Automatic updates are off. The scheduled process couldn’t be unloaded.")
            }
        }
        return "Automatic updates are off."
    }

    private func existingAgent() throws -> Data? {
        do {
            let values = try plist.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink == false else {
                throw HereforthError("The existing update LaunchAgent belongs to a different setup.")
            }
            let data = try Data(contentsOf: plist)
            guard let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  propertyList["Label"] as? String == Self.label,
                  propertyList["ProgramArguments"] as? [String] == program else {
                throw HereforthError("The existing update LaunchAgent belongs to a different setup.")
            }
            return data
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch CocoaError.fileNoSuchFile {
            return nil
        }
    }
}
