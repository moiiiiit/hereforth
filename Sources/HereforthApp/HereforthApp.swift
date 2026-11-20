import AppKit
import HereforthCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct HereforthApp: App {
    var body: some Scene {
        Window("Hereforth", id: "library") {
            LibraryView()
                .frame(minWidth: 810, minHeight: 500)
        }
        .defaultSize(width: 1040, height: 660)
    }
}

private struct LibraryView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var chats: [ChatInfo] = []
    @State private var briefs: [Brief] = []
    @State private var store: Store?
    @State private var selection: String? = "conversations"
    @State private var selectedChat: ChatInfo.ID?
    @State private var chatToRemove: ChatInfo?
    @State private var edits: [String: String] = [:]
    @State private var status = ""
    @State private var problem: String?
    @State private var importing = false

    private var selectedBrief: Brief? {
        briefs.first { "brief:" + $0.id == selection }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Library") {
                    Label("Conversations", systemImage: "bubble.left.and.bubble.right")
                        .tag("conversations")
                }
                Section("Draft briefs") {
                    ForEach(briefs) { brief in
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(brief.title).lineLimit(1)
                                Text(brief.recipient)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        } icon: {
                            Image(systemName: "doc.text")
                        }
                        .tag("brief:" + brief.id)
                    }
                    if briefs.isEmpty {
                        Text("No drafts yet")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 245)
        } detail: {
            VStack(spacing: 0) {
                if let brief = selectedBrief {
                    draftView(brief)
                } else {
                    library
                }
                Divider()
                HStack(spacing: 8) {
                    if importing {
                        ProgressView().controlSize(.small)
                        Text("Importing conversations…")
                    } else {
                        Image(systemName: "internaldrive")
                        Text(status.isEmpty ? "Stored on this Mac" : status)
                    }
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .frame(height: 34)
                .background(.bar)
            }
            .toolbar {
                Button(action: refresh) {
                    Label("Refresh Library", systemImage: "arrow.clockwise")
                }
                .help("Reload imported conversations and drafts")
                Button(action: importFiles) {
                    Label("Import Files…", systemImage: "square.and.arrow.down")
                }
                .disabled(importing)
                .help("Import conversation files")
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                if !importing, let updatedBriefs = try? store?.briefs() {
                    briefs = updatedBriefs
                    if selectedBrief == nil { selection = "conversations" }
                }
            }
        }
        .alert("Hereforth", isPresented: Binding(
            get: { problem != nil },
            set: { if !$0 { problem = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
        .confirmationDialog("Remove imported conversation?", isPresented: Binding(
            get: { chatToRemove != nil },
            set: { if !$0 { chatToRemove = nil } }
        ), presenting: chatToRemove) { chat in
            Button("Remove Conversation", role: .destructive) { remove(chat) }
        } message: { chat in
            Text("“\(chat.title)” will be removed from local search. Review any saved drafts or exported copies that quote it.")
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Conversations").font(.largeTitle.bold())
                Text(chats.isEmpty
                     ? "Build a local library from conversation exports."
                     : "\(chats.count) imported \(chats.count == 1 ? "conversation" : "conversations")")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            if chats.isEmpty {
                ContentUnavailableView {
                    Label("No conversations yet", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Import extracted ChatGPT or Claude JSON, a text file, or a Markdown file.")
                } actions: {
                    Button("Import Files…", action: importFiles)
                        .buttonStyle(.borderedProminent)
                        .disabled(importing)
                }
            } else {
                Table(chats, selection: $selectedChat) {
                    TableColumn("Title", value: \.title)
                    TableColumn("Source") { chat in
                        Text(chat.provider)
                            .foregroundStyle(.secondary)
                    }
                    .width(110)
                    TableColumn("Messages") { chat in
                        Text(chat.count, format: .number)
                            .monospacedDigit()
                    }
                    .width(80)
                }
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text("Ask Claude with Hereforth connected to create a draft brief. It will appear in the sidebar.")
                    Spacer()
                    Button("Remove…", role: .destructive) {
                        chatToRemove = chats.first { $0.id == selectedChat }
                    }
                    .disabled(selectedChat == nil || importing)
                    .help("Remove the selected conversation from the library")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            }
        }
    }

    private func draftView(_ brief: Brief) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(brief.title).font(.largeTitle.bold())
                    Text("Prepared for \(brief.recipient)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save Markdown…") { export(brief) }
                    .buttonStyle(.borderedProminent)
            }
            Text("Edits are saved to this local draft. Review the content before saving a copy to share.")
                .foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { edits[brief.id] ?? brief.markdown },
                set: { saveDraft(brief, text: $0) }
            ))
            .accessibilityLabel("Draft Markdown")
            .font(.system(.body, design: .monospaced))
            .padding(8)
            .background(.background)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.quaternary)
                    .allowsHitTesting(false)
            }
        }
        .padding(24)
    }

    private func refresh() {
        do {
            let store = try self.store ?? Store()
            let updatedChats = try store.chats()
            let updatedBriefs = try store.briefs()
            self.store = store
            chats = updatedChats
            briefs = updatedBriefs
            if !chats.contains(where: { $0.id == selectedChat }) { selectedChat = nil }
            if selectedBrief == nil { selection = "conversations" }
        } catch {
            problem = "The local library couldn’t be loaded. \(error.localizedDescription)"
        }
    }

    private func remove(_ chat: ChatInfo) {
        do {
            let store = try self.store ?? Store()
            try store.removeChat(chat.id)
            status = "Removed the selected conversation"
            refresh()
        } catch {
            problem = "The conversation couldn’t be removed. \(error.localizedDescription)"
        }
    }

    private func saveDraft(_ brief: Brief, text: String) {
        edits[brief.id] = text
        do {
            let store = try self.store ?? Store()
            try store.updateBrief(brief.id, markdown: text)
        } catch {
            problem = "Your edits are still in this window. The local draft couldn’t be updated. \(error.localizedDescription)"
        }
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.json, .plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        importing = true
        status = ""
        Task {
            let result = await Task.detached {
                var imported = 0
                var failures: [String] = []
                do {
                    let store = try Store()
                    for url in urls {
                        do {
                            imported += try store.importFile(url)
                        } catch {
                            failures.append(url.lastPathComponent + " — " + error.localizedDescription)
                        }
                    }
                } catch {
                    failures.append(error.localizedDescription)
                }
                return (imported, failures)
            }.value
            importing = false
            refresh()
            let (imported, failures) = result
            if !failures.isEmpty {
                problem = "Couldn’t import some of the selected files.\n\n" + failures.joined(separator: "\n")
            }
            if imported > 0 {
                status = "Imported \(imported) \(imported == 1 ? "conversation" : "conversations")"
            } else if failures.isEmpty {
                status = "No new conversations to import"
            }
        }
    }

    private func export(_ brief: Brief) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = brief.title
            .components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "-") + ".md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if let edit = edits[brief.id] {
                let store = try self.store ?? Store()
                try store.updateBrief(brief.id, markdown: edit)
            }
            try (edits[brief.id] ?? brief.markdown).write(to: url, atomically: true, encoding: .utf8)
            status = "Saved \(url.lastPathComponent)"
        } catch {
            problem = "The Markdown file couldn’t be saved. \(error.localizedDescription)"
        }
    }
}
