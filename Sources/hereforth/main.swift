import Foundation
import HereforthCore

let usage = """
Usage:
  hereforth import FILE...
  hereforth mcp
  hereforth voice show
  hereforth voice set  (reads UTF-8 writing notes from stdin)
  hereforth voice clear
  hereforth peer serve [PORT]
  hereforth peer invite SENDER
  hereforth peer revoke SENDER
  hereforth peer add PEER URL  (reads invitation token from stdin)
  hereforth peer remove PEER
"""

func writeError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func readVoiceNotes() throws -> String {
    let limit = Store.voiceNotesByteLimit
    var data = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: limit + 1 - data.count), !chunk.isEmpty {
        data.append(chunk)
        guard data.count <= limit else {
            throw HereforthError("Keep writing notes within \(limit) UTF-8 bytes.")
        }
    }
    guard let notes = String(data: data, encoding: .utf8) else {
        throw HereforthError("Provide writing notes as UTF-8 text.")
    }
    return notes
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "mcp" where arguments.count == 1:
        try MCPServer(store: Store()).run()
    case "peer":
        try PeerSettings.command(Array(arguments.dropFirst()))
    case "voice" where arguments.count == 2:
        switch arguments[1] {
        case "show":
            let notes = try Store().voiceNotes()
            FileHandle.standardOutput.write(Data(notes.utf8))
        case "set":
            let notes = try readVoiceNotes()
            guard !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HereforthError("Provide writing notes on stdin. Use ‘hereforth voice clear’ to remove existing notes.")
            }
            try Store().updateVoiceNotes(notes)
            print("Saved local writing notes.")
        case "clear":
            try Store().updateVoiceNotes("")
            print("Cleared local writing notes.")
        default:
            writeError(usage)
            exit(2)
        }
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
