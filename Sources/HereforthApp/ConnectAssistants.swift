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
        case kimi = "kimi-code"
        case openCode
        case lmStudio
        case manual

        var id: String { rawValue }

        var name: String {
            switch self {
            case .desktop: return "Claude Desktop"
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            case .kimi: return "Kimi Code"
            case .openCode: return "OpenCode"
            case .lmStudio: return "LM Studio"
            case .manual: return "Other Local MCP Client"
            }
        }

        var usesManualSetup: Bool {
            self == .openCode || self == .lmStudio || self == .manual
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
                Section("Connect") {
                    ForEach(Assistant.allCases.filter { !$0.usesManualSetup }) { option in
                        Text(option.name).tag(option)
                    }
                }
                Section("Set Up Manually") {
                    ForEach(Assistant.allCases.filter(\.usesManualSetup)) { option in
                        Text(option.name).tag(option)
                    }
                }
            }
            .pickerStyle(.menu)
            .disabled(connecting)
            .onChange(of: assistant) {
                executable = nil
                result = nil
            }

            if assistant == .claude || assistant == .codex {
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

            if assistant.usesManualSetup {
                manualSetup
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
                if assistant.usesManualSetup {
                    Button(assistant == .lmStudio ? "Copy JSON Configuration" : "Copy Command",
                           action: copySetup)
                        .buttonStyle(.borderedProminent)
                        .disabled(Self.helperExecutable == nil)
                } else {
                    Button("Connect \(assistant.name)", action: connect)
                        .buttonStyle(.borderedProminent)
                        .disabled(connecting)
                }
            }
        }
        .padding(23)
        .frame(width: 450, alignment: .leading)
    }

    private var manualSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let helper = Self.helperExecutable {
                switch assistant {
                case .openCode:
                    Text("Run the copied command in Terminal from the project where you use OpenCode.")
                case .lmStudio:
                    Text("In LM Studio’s Program panel, choose Install, then Edit mcp.json. Merge the hereforth entry into mcpServers.")
                default:
                    Text("Add a server named hereforth using local stdio transport.")
                    LabeledContent("Executable") {
                        Text(helper.path)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    LabeledContent("Arguments") {
                        Text("mcp")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            } else {
                Text("Open the installed Hereforth app to get its helper path.")
            }
        }
        .foregroundStyle(.secondary)
    }

    private func copySetup() {
        guard let helper = Self.helperExecutable else { return }
        let command = helper.path
        let setup: String
        if assistant == .manual || assistant == .openCode {
            let launch = "'" + command.replacingOccurrences(of: "'", with: "'\\''") + "' mcp"
            setup = assistant == .openCode ? "opencode mcp add hereforth -- " + launch : launch
        } else {
            let entry = ["mcpServers": ["hereforth": ["command": command, "args": ["mcp"]] as [String: Any]]]
            guard let data = try? JSONSerialization.data(withJSONObject: entry,
                                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            else { return }
            setup = String(decoding: data, as: UTF8.self)
        }
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        let copied = clipboard.setString(setup, forType: .string)
        result = ConnectionResult(message: copied ? "Copied to the clipboard." : "Couldn’t copy to the clipboard.",
                                  failed: !copied)
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

    private nonisolated static var helperExecutable: URL? {
        guard let helper = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("hereforth"),
              FileManager.default.isExecutableFile(atPath: helper.path) else { return nil }
        return helper
    }

    private nonisolated static func register(_ client: String, executable: String?) -> ConnectionResult {
        guard let helper = helperExecutable else {
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
