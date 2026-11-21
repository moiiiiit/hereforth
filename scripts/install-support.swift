import Darwin
import Foundation

private enum InstallationError: Error {
    case unexpectedBundle
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

let args = CommandLine.arguments
guard args.count == 4, args[1] == "bundle" else { exit(2) }
do {
    try installBundle(from: args[2], at: args[3])
} catch {
    let message = "Couldn’t install the app. Check that ~/Applications is writable and Hereforth.app belongs to this installer.\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}
