import AppKit
import HereforthCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct HereforthApp: App {
    @StateObject private var awake = KeepAwake()
    @StateObject private var phoneListener = PhoneListenerProcess()
    @State private var selection: String? = "conversations"

    #if HEREFORTH_BINARY_UPDATER
    @StateObject private var binaryUpdates = BinaryUpdater()
    #endif

    var body: some Scene {
        Window("Hereforth", id: "library") {
            LibraryView(awake: awake, phoneListener: phoneListener, selection: $selection)
                .frame(minWidth: 810, minHeight: 500)
        }
        .defaultSize(width: 1040, height: 660)
        .commands {
            LibraryCommands()
            ConnectAssistantCommands()
            #if HEREFORTH_BINARY_UPDATER
            BinaryUpdateCommands(updates: binaryUpdates)
            #endif
        }

        Window("Connect Assistants", id: "connect-assistants") {
            ConnectAssistantsView()
        }
        .windowResizability(.contentSize)

        MenuBarExtra("Hereforth", systemImage: awake.mode == nil ? "h.square" : "h.square.fill") {
            HereforthMenu(awake: awake, selection: $selection)
        }

        #if HEREFORTH_BINARY_UPDATER
        Settings { BinaryUpdateSettings(updates: binaryUpdates) }
        #endif
    }
}

private struct LibraryFind: FocusedValueKey {
    typealias Value = () -> Void
}

private extension FocusedValues {
    var libraryFind: (() -> Void)? {
        get { self[LibraryFind.self] }
        set { self[LibraryFind.self] = newValue }
    }
}

private struct LibraryCommands: Commands {
    @FocusedValue(\.libraryFind) private var find

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find Conversations") { find?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(find == nil)
        }
    }
}

private struct LibraryView: View {
    @ObservedObject var awake: KeepAwake
    @ObservedObject var phoneListener: PhoneListenerProcess
    @Binding var selection: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var chats: [ChatInfo] = []
    @State private var briefs: [Brief] = []
    @State private var offers: [ContextOffer] = []
    @State private var requests: [WorkRequest] = []
    @State private var ownerTasks: [OwnerTask] = []
    @State private var standupThreads: [StandupThread] = []
    @State private var standupPage: StandupPage = .week
    @State private var standupSelection: StandupThread.ID?
    @State private var openingUpdates: [String: String] = [:]
    @State private var standupReplies: [String: String] = [:]
    @State private var store: Store?
    @State private var selectedChat: ChatInfo.ID?
    @State private var chatToRemove: ChatInfo?
    @State private var edits: [String: String] = [:]
    @State private var status = ""
    @State private var problem: String?
    @State private var importing = false
    @State private var filter = ""
    @FocusState private var filterFocused: Bool
    @State private var findRequested = false

    private var accent: Color {
        colorScheme == .dark ? Color(red: 0.59, green: 0.83, blue: 0.74)
            : Color(red: 0.137, green: 0.329, blue: 0.275)
    }

    private var paper: Color {
        colorScheme == .dark ? Color(nsColor: .windowBackgroundColor)
            : Color(red: 0.981, green: 0.973, blue: 0.951)
    }

    private var selectedBrief: Brief? {
        briefs.first { "brief:" + $0.id == selection }
    }

    private var visibleChats: [ChatInfo] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return chats }
        return chats.filter {
            $0.title.localizedStandardContains(query) || $0.provider.localizedStandardContains(query)
        }
    }

    private var showsFirstRun: Bool {
        chats.isEmpty && selection == "conversations"
    }

    private var pendingRequests: Int {
        offers.lazy.filter { $0.state == "pending" }.count
    }

    private var pendingWork: Int {
        requests.lazy.filter { $0.state == "pending" }.count
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Library") {
                    Label("Conversations", systemImage: "bubble.left.and.bubble.right")
                        .tag("conversations")
                }
                Section("Handoffs") {
                    queueRow("Inbox", icon: "tray", count: pendingRequests)
                        .tag("inbox")
                    queueRow("Work Requests", icon: "checklist", count: pendingWork)
                        .tag("requests")
                    Label("Standup", systemImage: "calendar")
                        .tag("standup")
                    if briefs.isEmpty {
                        Label("Local Drafts", systemImage: "doc.text")
                            .tag("handoffs")
                    }
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
                }
                Section("On This Mac") {
                    Label("Usage", systemImage: "chart.bar.xaxis")
                        .tag("usage")
                    Label("Keep Awake", systemImage: "cup.and.saucer")
                        .tag("power")
                    queueRow("Phone Access", icon: "iphone",
                             count: ownerTasks.lazy.filter { $0.state == "pending_review" }.count)
                        .tag("phone")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 205, ideal: 228)
        } detail: {
            VStack(spacing: 0) {
                if selection == "inbox" {
                    ContextInbox(offers: offers, onReview: reviewContext)
                } else if selection == "usage" {
                    UsageView()
                } else if selection == "power" {
                    KeepAwakeView(awake: awake)
                } else if selection == "phone" {
                    PhoneAccessView(tasks: ownerTasks, listener: phoneListener, review: reviewOwnerTask)
                } else if selection == "requests" {
                    WorkRequests(
                        requests: requests,
                        briefs: briefs,
                        previewDraft: previewWorkRequest,
                        review: reviewWorkRequest,
                        revoke: revokeWorkRequest,
                        approveStandup: approveStandup,
                        openStandup: openStandup,
                        openingUpdates: $openingUpdates
                    )
                } else if selection == "standup", let store {
                    StandupView(
                        store: store, threads: standupThreads,
                        page: $standupPage, selection: $standupSelection, replies: $standupReplies,
                        revoke: revokeWorkRequest
                    )
                } else if let brief = selectedBrief {
                    BriefReview(
                        title: brief.title,
                        recipient: brief.recipient,
                        markdown: Binding(
                            get: { edits[brief.id] ?? brief.markdown },
                            set: { saveDraft(brief, text: $0) }
                        ),
                        onExport: { export(brief) }
                    )
                    .id(brief.id)
                } else if selection == "handoffs" {
                    emptyHandoffs
                } else {
                    library
                }
                Divider()
                HStack(spacing: 8) {
                    if importing {
                        ProgressView().controlSize(.small)
                        Text("Importing conversations…")
                    } else {
                        Image(systemName: status.isEmpty ? "internaldrive" : "checkmark.circle")
                            .accessibilityHidden(true)
                        Text(status.isEmpty ? "On this Mac" : status)
                    }
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .frame(height: 34)
                .background(.bar)
            }
            .background(paper)
            .toolbar {
                Button(action: refresh) {
                    Label("Refresh Library", systemImage: "arrow.clockwise")
                }
                .help("Reload imported conversations and drafts")
                if !showsFirstRun {
                    Button(action: importFiles) {
                        Label("Import Files…", systemImage: "square.and.arrow.down")
                    }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(importing)
                    .help("Import conversation files (⌘I)")
                }
            }
        }
        .tint(accent)
        .focusedSceneValue(\.libraryFind, chats.isEmpty ? nil : findConversations)
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
                    validateSelection()
                }
                if let incoming = try? store?.contextInbox() {
                    offers = incoming
                }
                if let incoming = try? store?.workRequests() {
                    requests = incoming
                }
                if let updated = try? store?.standupThreads() {
                    standupThreads = updated
                }
                if let updated = try? store?.ownerTasks() {
                    ownerTasks = updated
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

    private func queueRow(_ title: String, icon: String, count: Int) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer(minLength: 8)
            if count > 0 {
                Text(count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(count) waiting for review")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var library: some View {
        Group {
            if chats.isEmpty {
                ContentUnavailableView {
                    VStack(spacing: 14) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 56, height: 56)
                            .accessibilityHidden(true)
                        Text("Import your conversations")
                            .font(.title2.weight(.semibold))
                    }
                } description: {
                    Text("Add an extracted ChatGPT or Claude JSON export, a text file, or a Markdown file.")
                } actions: {
                    Button(action: importFiles) {
                        Text("Import Files…")
                            .foregroundStyle(colorScheme == .dark ? Color.black : .white)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(importing)
                    .help("Import conversation files (⌘I)")
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Conversations")
                                .font(.title.weight(.semibold))
                                .accessibilityAddTraits(.isHeader)
                            Text(conversationCount)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        filterField
                    }
                    .padding(24)
                    Divider()
                    if visibleChats.isEmpty {
                        ContentUnavailableView {
                            Label("No matching conversations", systemImage: "magnifyingglass")
                        } description: {
                            Text("Try a different title or source.")
                        }
                    } else {
                        Table(visibleChats, selection: $selectedChat) {
                            TableColumn("Title", value: \.title)
                            TableColumn("Source") { chat in
                                Text(chat.provider)
                                    .foregroundStyle(.secondary)
                            }
                            .width(105)
                            TableColumn("Messages") { chat in
                                Text(chat.count, format: .number)
                                    .monospacedDigit()
                            }
                            .width(80)
                        }
                        .contextMenu(forSelectionType: ChatInfo.ID.self) { items in
                            if let id = items.first,
                               let chat = visibleChats.first(where: { $0.id == id }) {
                                Button("Remove Conversation…", role: .destructive) {
                                    chatToRemove = chat
                                }
                                .disabled(importing)
                            }
                        }
                        Divider()
                        HStack {
                            Spacer()
                            Button("Remove Conversation…") {
                                chatToRemove = visibleChats.first { $0.id == selectedChat }
                            }
                            .disabled(selectedChat == nil || importing)
                            .help("Remove the selected conversation from local search")
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var conversationCount: String {
        let total = chats.count
        let shown = visibleChats.count
        if total == shown { return "\(total) \(total == 1 ? "conversation" : "conversations")" }
        return "\(shown) of \(total) conversations"
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Filter by title or source", text: $filter)
                .textFieldStyle(.plain)
                .focused($filterFocused)
                .help("Filter conversations by title or source (⌘F)")
                .onExitCommand {
                    if filter.isEmpty {
                        filterFocused = false
                    } else {
                        filter = ""
                    }
                }
                .onChange(of: filter) { _, _ in
                    if !visibleChats.contains(where: { $0.id == selectedChat }) {
                        selectedChat = nil
                    }
                }
                .task(id: findRequested) {
                    guard findRequested else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    filterFocused = true
                    findRequested = false
                }
            Button {
                filter = ""
                filterFocused = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Clear Conversation Filter")
            .help("Clear the conversation filter")
            .opacity(filter.isEmpty ? 0 : 1)
            .disabled(filter.isEmpty)
            .accessibilityHidden(filter.isEmpty)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(width: 220)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(filterFocused ? accent : Color(nsColor: .separatorColor))
                .allowsHitTesting(false)
        }
    }

    private var emptyHandoffs: some View {
        ContentUnavailableView {
            Label("No local drafts yet", systemImage: "doc.text")
        } description: {
            Text("Ask your connected assistant to prepare a draft if you want to edit or export it locally.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func findConversations() {
        if selection == "conversations" {
            filterFocused = true
        } else {
            findRequested = true
            selection = "conversations"
        }
    }

    private func validateSelection() {
        if selection == "handoffs", let latest = briefs.first {
            selection = "brief:" + latest.id
        } else if !["handoffs", "inbox", "requests", "standup", "usage", "power", "phone"].contains(selection ?? ""), selectedBrief == nil {
            selection = "conversations"
        }
    }

    private func refresh() {
        do {
            let store = try self.store ?? Store()
            let updatedChats = try store.chats()
            let updatedBriefs = try store.briefs()
            let incoming = try store.contextInbox()
            let incomingWork = try store.workRequests()
            let updatedThreads = try store.standupThreads()
            let updatedTasks = try store.ownerTasks()
            self.store = store
            chats = updatedChats
            briefs = updatedBriefs
            offers = incoming
            requests = incomingWork
            standupThreads = updatedThreads
            ownerTasks = updatedTasks
            if !visibleChats.contains(where: { $0.id == selectedChat }) { selectedChat = nil }
            validateSelection()
        } catch {
            problem = "The local library couldn’t be loaded. \(error.localizedDescription)"
        }
    }

    private func reviewOwnerTask(_ id: String, _ approve: Bool) throws {
        let store = try self.store ?? Store()
        defer { if let updated = try? store.ownerTasks() { ownerTasks = updated } }
        _ = try store.reviewOwnerTask(id: id, approve: approve)
    }

    private func reviewContext(_ id: String, approve: Bool) {
        do {
            let store = try self.store ?? Store()
            try store.reviewContext(id: id, approve: approve)
            offers = try store.contextInbox()
        } catch {
            if let incoming = try? store?.contextInbox() { offers = incoming }
            problem = "The context request couldn’t be updated. \(error.localizedDescription)"
        }
    }

    private func previewWorkRequest(_ id: String, _ briefID: String) throws -> WorkRequestPreview {
        let store = try self.store ?? Store()
        return try store.previewWorkRequest(id: id, briefID: briefID)
    }

    private func reviewWorkRequest(_ id: String, _ approve: Bool, _ preview: WorkRequestPreview?) throws {
        let store = try self.store ?? Store()
        defer { if let updated = try? store.workRequests() { requests = updated } }
        _ = try store.reviewWorkRequest(id: id, approve: approve,
                                        briefID: preview?.briefID, digest: preview?.digest)
    }

    private func revokeWorkRequest(_ id: String) throws {
        let store = try self.store ?? Store()
        defer {
            if let updated = try? store.workRequests() { requests = updated }
            if let updated = try? store.standupThreads() { standupThreads = updated }
        }
        try store.revokeWorkRequest(id: id)
    }

    private func approveStandup(_ id: String, _ text: String) throws {
        let store = try self.store ?? Store()
        let thread = try store.reviewStandupRequest(id: id, approvedText: text)
        if let updated = try? store.workRequests() { requests = updated }
        if let updated = try? store.standupThreads() { standupThreads = updated }
        showStandupThread(thread.id)
    }

    private func openStandup(_ requestID: String) {
        do {
            let store = try self.store ?? Store()
            standupThreads = try store.standupThreads()
            guard let thread = standupThreads.first(where: { $0.requestID == requestID }) else {
                problem = "The standup thread couldn’t be found."
                return
            }
            showStandupThread(thread.id)
        } catch {
            problem = "The standup thread couldn’t be opened. \(error.localizedDescription)"
        }
    }

    private func showStandupThread(_ id: StandupThread.ID) {
        standupPage = .threads
        standupSelection = id
        selection = "standup"
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
