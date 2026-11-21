import AppKit
import SwiftUI

struct ConnectAssistantCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Connect Assistants…") { openWindow(id: "connect-assistants") }
        }
    }
}

struct ConnectAssistantsView: View {
    private enum Assistant: String, CaseIterable, Identifiable, Sendable {
        case desktop = "claude-desktop"
        case claude = "claude-code"
        case codex

        var id: String { rawValue }

        var name: String {
            switch self {
            case .desktop: return "Claude Desktop"
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            }
        }
    }

    @State private var assistant: Assistant = .desktop
    @State private var executable: URL?
    @State private var result: ConnectionResult?
    @State private var connecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Connect an assistant")
                .font(.title2.weight(.semibold))
            Text("Add Hereforth to an assistant installed on this Mac.")
                .foregroundStyle(.secondary)

            Picker("Assistant", selection: $assistant) {
                ForEach(Assistant.allCases) { option in
                    Text(option.name).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .disabled(connecting)
            .onChange(of: assistant) {
                executable = nil
                result = nil
            }

            if assistant != .desktop {
                HStack {
                    Button("Choose CLI executable…", action: chooseExecutable)
                        .buttonStyle(.link)
                        .disabled(connecting)
                    if let executable {
                        Text(executable.lastPathComponent)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            if let result {
                Text(result.message)
                    .foregroundStyle(result.failed ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel(result.message)
            }

            HStack {
                if connecting { ProgressView().controlSize(.small).accessibilityLabel("Connecting") }
                Spacer()
                Button("Connect \(assistant.name)", action: connect)
                    .buttonStyle(.borderedProminent)
                    .disabled(connecting)
            }
        }
        .padding(23)
        .frame(width: 450, alignment: .leading)
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { executable = panel.url }
    }

    private func connect() {
        let client = assistant.rawValue
        let path = executable?.path
        connecting = true
        result = nil
        Task {
            result = await Task.detached(priority: .userInitiated) {
                Self.register(client, executable: path)
            }.value
            connecting = false
        }
    }

    private struct ConnectionResult: Sendable {
        let message: String
        let failed: Bool
    }

    private nonisolated static func register(_ client: String, executable: String?) -> ConnectionResult {
        guard let helper = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("hereforth"),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            return ConnectionResult(message: "Open the installed Hereforth app to connect an assistant.", failed: true)
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = helper
        process.arguments = ["connect", client] + (executable.map { [$0] } ?? [])
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus == 0 {
                return ConnectionResult(message: detail + " Reopen the assistant or start a fresh chat.", failed: false)
            }
            return ConnectionResult(message: detail.isEmpty ? "The assistant couldn’t be connected." : detail, failed: true)
        } catch {
            return ConnectionResult(message: "The Hereforth helper couldn’t start.", failed: true)
        }
    }
}
