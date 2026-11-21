import AppKit
import HereforthCore
import SwiftUI

struct PhoneAccessView: View {
    let tasks: [OwnerTask]
    @ObservedObject var listener: PhoneListenerProcess
    let review: (String, Bool) throws -> Void

    @State private var selection: OwnerTask.ID?
    @State private var showingSetup = false

    private var pending: Int {
        tasks.lazy.filter { $0.state == "pending_review" }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Phone Access")
                        .font(.title.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    if pending > 0 {
                        Text(pending == 1 ? "1 prompt to review" : "\(pending) prompts to review")
                            .foregroundStyle(.secondary)
                    }
                    Text(listener.status)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if listener.running {
                    Button("Stop Listener") { listener.stop() }
                } else {
                    Button("Start Listener") { listener.start() }
                }
                Button("Set Up Phone Access…") { showingSetup = true }
            }
            .padding(24)
            Divider()

            if tasks.isEmpty {
                ContentUnavailableView {
                    Label("No phone requests", systemImage: "iphone")
                } description: {
                    Text("Prompts you queue from your phone appear here for review.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(selection: $selection) {
                        ForEach(tasks) { task in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: task.prompt)
                                    .fontWeight(.medium)
                                Text(task.clientName + " · " + taskType(task))
                                    .foregroundStyle(.secondary)
                                Text(taskStatus(task))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .lineLimit(1)
                            .padding(.vertical, 3)
                            .accessibilityElement(children: .combine)
                            .tag(task.id)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .frame(minWidth: 155, idealWidth: 205, maxWidth: 300)

                    if let task = tasks.first(where: { $0.id == selection }) {
                        TaskReview(task: task, review: review)
                            .id(task.id)
                            .frame(minWidth: 375)
                    } else {
                        ContentUnavailableView("Select a phone request", systemImage: "iphone")
                            .frame(minWidth: 375)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: tasks.map(\.id), initial: true) { _, ids in
            if let selection, ids.contains(selection) { return }
            selection = (tasks.first { $0.state == "pending_review" } ?? tasks.first)?.id
        }
        .sheet(isPresented: $showingSetup) {
            PhoneSetup()
        }
    }
}

private struct PhoneSetup: View {
    @Environment(\.dismiss) private var dismiss

    private var helper: String {
        let path = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("hereforth").path ?? "/Applications/Hereforth.app/Contents/MacOS/hereforth"
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Up Phone Access")
                .font(.title2.weight(.semibold))
            Text("Connect your Mac and phone to the same private tailnet. Configure your own Mac hostname and Tailscale sign-in email in Terminal.")
            Text("\(helper) phone configure https://your-mac.example.ts.net:9444 owner@example.com 9125")
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text("Click Start Listener in Hereforth. Once it’s running, use an unused HTTPS port to expose only this listener.")
            Text("tailscale serve --bg --https=9444 http://127.0.0.1:9125")
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text("Generate a one-time code in Terminal.")
            Text("\(helper) phone pair")
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Button("Copy Pair Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(helper) phone pair", forType: .string)
            }
            Text("Open the private HTTPS address on your phone. Enter the code and create a passkey. The listener stays available while Hereforth is running, even with its window closed.")
                .foregroundStyle(.secondary)
            HStack {
                Link("Tailscale Serve instructions", destination: URL(string: "https://tailscale.com/docs/features/tailscale-serve")!)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 550)
    }
}

@MainActor
final class PhoneListenerProcess: ObservableObject {
    @Published private(set) var status = "Listener stopped"
    @Published private(set) var running = false

    private var process: Process?
    private var terminationObserver: NSObjectProtocol?
    private var output = ""
    private var errorOutput = ""

    init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    func start() {
        guard process == nil else { return }
        guard let helper = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("hereforth"),
              FileManager.default.isExecutableFile(atPath: helper.path)
        else {
            status = "Open the installed Hereforth app to start the listener."
            return
        }
        let child = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        child.executableURL = helper
        child.arguments = ["phone", "serve", "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = stdout
        child.standardError = stderr
        output = ""
        errorOutput = ""
        observe(stdout, child: child, isError: false)
        observe(stderr, child: child, isError: true)
        child.terminationHandler = { [weak self] child in
            Task { @MainActor in
                guard let self, self.process === child else { return }
                let stopped = self.status == "Stopping listener…" || child.terminationStatus == 0
                self.running = false
                self.process = nil
                self.status = stopped ? "Listener stopped" :
                    (self.errorOutput.isEmpty ? "The listener couldn’t start. Check the setup and try again." : self.errorOutput)
            }
        }
        do {
            try child.run()
            process = child
            running = true
            status = "Starting listener…"
        } catch {
            status = "Hereforth couldn’t start its phone listener."
        }
    }

    func stop() {
        guard let process, process.isRunning else { return }
        status = "Stopping listener…"
        process.terminate()
    }

    private func observe(_ pipe: Pipe, child: Process, isError: Bool) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak child] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor in
                guard let self, let child, self.process === child else { return }
                let chunk = String(decoding: data.prefix(1024), as: UTF8.self)
                if isError {
                    self.errorOutput = String((self.errorOutput + chunk).prefix(1024))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    self.output = String((self.output + chunk).prefix(64))
                    if self.output.split(whereSeparator: \.isNewline).contains("ready") {
                        self.status = "Listener running on this Mac"
                    }
                }
            }
        }
    }
}

private struct TaskReview: View {
    let task: OwnerTask
    let review: (String, Bool) throws -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var feedback: String?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(task.clientName + " · " + taskType(task))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(taskStatus(task))
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Exact prompt").font(.headline)
                    Text(verbatim: task.prompt)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }

            if task.state != "declined" {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(task.state == "approved"
                         ? "Copy the prompt and paste it into a fresh \(task.clientName) session. Review permissions in the client."
                         : "Approve the prompt here to use it in a new \(task.clientName) session.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        if let feedback {
                            Text(feedback).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if task.state == "pending_review" {
                            Button("Decline") { decide(false) }
                            primary("Approve Prompt") { decide(true) }
                        } else if task.state == "approved" {
                            Button("Open \(task.clientName)") { openClient() }
                            primary("Copy Prompt") { copyPrompt() }
                        }
                    }
                }
                .padding(16)
            }
        }
        .alert("Phone Access", isPresented: Binding(
            get: { problem != nil },
            set: { if !$0 { problem = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private func primary(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .foregroundStyle(colorScheme == .dark ? Color.black : .white)
        }
        .buttonStyle(.borderedProminent)
    }

    private func decide(_ approve: Bool) {
        do { try review(task.id, approve) } catch { problem = error.localizedDescription }
    }

    private func copyPrompt() {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(task.prompt, forType: .string) {
            feedback = "Copied"
        } else {
            problem = "The prompt couldn’t be copied."
        }
    }

    private func openClient() {
        let bundleID = task.client == "codex" ? "com.openai.codex" : "com.anthropic.claudefordesktop"
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           NSWorkspace.shared.open(url) { return }
        problem = "Open \(task.clientName) yourself or use its official command-line client to start a fresh session."
    }
}

private extension OwnerTask {
    var clientName: String { client == "codex" ? "Codex" : "Claude Code" }
}

private func taskType(_ task: OwnerTask) -> String {
    task.kind == "computer" ? "Computer use" : "Text task"
}

private func taskStatus(_ task: OwnerTask) -> String {
    switch task.state {
    case "pending_review": "Needs review on this Mac"
    case "approved": "Prompt approved · Ready to copy"
    case "declined": "Declined"
    default: "Unavailable"
    }
}
