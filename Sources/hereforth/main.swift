import Foundation
import HereforthCore

let usage = """
Usage:
  hereforth import FILE...
  hereforth mcp
  hereforth peer serve [PORT]
  hereforth peer invite SENDER
  hereforth peer revoke SENDER
  hereforth peer add PEER URL  (reads invitation token from stdin)
  hereforth peer remove PEER
"""

func writeError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "mcp" where arguments.count == 1:
        try MCPServer(store: Store()).run()
    case "peer":
        try PeerSettings.command(Array(arguments.dropFirst()))
    case "import" where arguments.count > 1:
        let store = try Store()
        var failed = false
        for path in arguments.dropFirst() {
            let url = URL(fileURLWithPath: path)
            do {
                let count = try store.importFile(url)
                print("\(url.lastPathComponent): imported \(count) conversation(s).")
            } catch {
                writeError("\(url.lastPathComponent): \(error.localizedDescription)")
                failed = true
            }
        }
        if failed { exit(1) }
    case nil, "--help", "-h":
        print(usage)
    default:
        writeError(usage)
        exit(2)
    }
} catch {
    writeError("Hereforth: \(error.localizedDescription)")
    exit(1)
}
