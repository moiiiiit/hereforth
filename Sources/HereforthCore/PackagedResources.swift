import Foundation

private final class HereforthResourcesAnchor: NSObject {}

enum PackagedResources {
    static let directories: [URL] = {
        let containingBundle = Bundle(for: HereforthResourcesAnchor.self)
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        return [
            Bundle.main.resourceURL,
            executable?.deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true),
            executable,
            Bundle.main.bundleURL,
            containingBundle.bundleURL.deletingLastPathComponent()
        ].compactMap { $0 }
    }()

    // SwiftPM's generated Bundle.module traps when an optional resource bundle is missing.
    static func load(_ path: String, in directories: [URL] = directories) -> Data? {
        for directory in directories {
            let bundle = directory.appendingPathComponent("Hereforth_HereforthCore.bundle", isDirectory: true)
            guard let resources = Bundle(url: bundle)?.resourceURL else { continue }
            if let bytes = try? Data(contentsOf: resources.appendingPathComponent(path)), !bytes.isEmpty { return bytes }
        }
        return nil
    }
}

public enum PhoneWebAssets {
    public static func load(_ name: String) -> Data? {
        guard ["index.html", "app.js", "styles.css"].contains(name) else { return nil }
        return PackagedResources.load("PhoneWeb/" + name)
    }
}
