import HereforthCore
import SwiftUI

enum StandupPage: Hashable {
    case week
    case threads
}

struct StandupView: View {
    let store: Store
    let threads: [StandupThread]
    @Binding var page: StandupPage
    @Binding var selection: StandupThread.ID?
    @Binding var replies: [String: String]
    let revoke: (String) throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 20) {
                Text("Standup")
                    .font(.title.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Picker("Standup View", selection: $page) {
                    Text("This Week").tag(StandupPage.week)
                    Text("Threads").tag(StandupPage.threads)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(24)
            Divider()
            switch page {
            case .week:
                WeeklyStandupView(store: store)
            case .threads:
                threadList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var threadList: some View {
        Group {
            if threads.isEmpty {
                ContentUnavailableView {
                    Label("No standup threads", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Review a standup access request in Work Requests to open a thread.")
                }
            } else {
                HSplitView {
                    List(selection: $selection) {
                        ForEach(threads) { thread in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: thread.sender)
                                    .fontWeight(.medium)
                                Text(threadStatus(thread.state))
                                    .foregroundStyle(.secondary)
                            }
                            .lineLimit(1)
                            .padding(.vertical, 4)
                            .accessibilityElement(children: .combine)
                            .tag(thread.id)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .frame(minWidth: 155, idealWidth: 205, maxWidth: 300)

                    if let thread = threads.first(where: { $0.id == selection }) {
                        StandupThreadView(
                            store: store,
                            thread: thread,
                            reply: Binding(
                                get: { replies[thread.id] ?? "" },
                                set: { replies[thread.id] = $0 }
                            ),
                            revoke: revoke
                        )
                        .id(thread.id)
                        .frame(minWidth: 375)
                    } else {
                        ContentUnavailableView("Select a standup thread", systemImage: "bubble.left")
                            .frame(minWidth: 375)
                    }
                }
            }
        }
        .onChange(of: threads.map(\.id), initial: true) { _, ids in
            if let selection, ids.contains(selection) { return }
            selection = (threads.first { $0.state == "active" } ?? threads.first)?.id
        }
    }
}

private struct WeeklyStandupView: View {
    let store: Store

    @State private var selectedChat: WeeklyChat.ID?
    @State private var contributingChats: [WeeklyChat] = []
    @State private var inventoryCursor: String?
    @State private var snapshot: WeeklyContextPage?
    @State private var entries: [WeeklyEvidence] = []
    @State private var problem: String?
    @State private var asOf = Date()
    @State private var timeZone = TimeZone.current

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This Week")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    if let snapshot {
                        Text(weekLabel(snapshot))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Picker("Filter by Conversation", selection: $selectedChat) {
                    Text("All Conversations").tag(nil as WeeklyChat.ID?)
                    ForEach(contributingChats) { chat in
                        Text(conversationLabel(chat)).tag(Optional(chat.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 225)
                .disabled(contributingChats.isEmpty)
                .help("Show this week’s evidence from one conversation")
                if let cursor = inventoryCursor {
                    Button("More") { loadMoreConversations(cursor: cursor) }
                        .accessibilityLabel("Load More Conversations")
                        .help("Show more conversations with dated evidence this week")
                }
                Button {
                    refreshWeek()
                } label: {
                    Label("Refresh This Week", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .help("Reload this week’s evidence")
            }
            .padding(20)
            Divider()

            if let problem {
                ContentUnavailableView {
                    Label("Can’t load this week", systemImage: "exclamationmark.circle")
                } description: {
                    Text(problem)
                } actions: {
                    Button("Reload This Week") { refreshWeek() }
                }
            } else if entries.isEmpty {
                ContentUnavailableView {
                    Label("No dated evidence this week", systemImage: "calendar")
                } description: {
                    Text(snapshot?.hasUndatedSources == true
                         ? "Undated passages remain in the local library. This view uses dates to place evidence in the week."
                         : "This view shows dated passages from your imported conversations.")
                } actions: {
                    if selectedChat != nil {
                        Button("Show All Conversations") { selectedChat = nil }
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 15) {
                        if snapshot?.hasUndatedSources == true {
                            Text("This week includes dated passages. Undated passages remain in your library.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(entries, id: \.citation) { entry in
                            evidence(entry)
                            Divider()
                        }
                        if let cursor = snapshot?.nextCursor {
                            Button("Load More Evidence") { load(cursor: cursor) }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .task { refreshWeek() }
        .onChange(of: selectedChat) { _, _ in load() }
    }

    private func evidence(_ entry: WeeklyEvidence) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: entry.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("\(entry.provider) · \(entry.role) · \(shortDate(entry.date))")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(verbatim: entry.excerpt)
            HStack(spacing: 8) {
                Text(verbatim: entry.citation)
                    .font(.caption.monospaced())
                    .accessibilityLabel("Source citation \(entry.citation)")
                if entry.excerptTruncated {
                    Text("Excerpt")
                        .font(.caption)
                }
            }
            .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
    }

    private func load(cursor: String? = nil) {
        do {
            let page = try store.weeklyContext(now: asOf, timeZone: timeZone, cursor: cursor, chatID: selectedChat)
            if cursor == nil {
                entries = page.entries
            } else {
                entries.append(contentsOf: page.entries)
            }
            snapshot = page
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func refreshWeek() {
        asOf = Date()
        timeZone = .current
        do {
            let page = try store.weeklyInventory(now: asOf, timeZone: timeZone, limit: 25)
            contributingChats = page.entries
            inventoryCursor = page.nextCursor
            if let selectedChat, !contributingChats.contains(where: { $0.id == selectedChat }) {
                self.selectedChat = nil
            } else {
                load()
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    private func loadMoreConversations(cursor: String) {
        do {
            let page = try store.weeklyInventory(now: asOf, timeZone: timeZone, cursor: cursor, limit: 25)
            contributingChats.append(contentsOf: page.entries)
            inventoryCursor = page.nextCursor
        } catch {
            problem = error.localizedDescription
        }
    }

    private func conversationLabel(_ chat: WeeklyChat) -> String {
        let title = chat.titleTruncated ? chat.title + "…" : chat.title
        let count = chat.count == 1 ? "1 passage" : "\(chat.count) passages"
        return "\(title) · \(chat.provider) · \(count) · \(shortDate(chat.newestDate))"
    }

    private func weekLabel(_ snapshot: WeeklyContextPage) -> String {
        let zone = TimeZone(identifier: snapshot.timeZone) ?? .current
        guard let first = standupDate(snapshot.weekStart),
              let exclusiveEnd = standupDate(snapshot.weekEnd) else { return snapshot.timeZone }
        let last = exclusiveEnd.addingTimeInterval(-1)
        var format = Date.FormatStyle().month(.abbreviated).day()
        format.timeZone = zone
        return "\(first.formatted(format))–\(last.formatted(format)) · \(snapshot.timeZone)"
    }

    private func shortDate(_ value: String) -> String {
        guard let date = standupDate(value) else { return value }
        var formatter = Date.FormatStyle().month(.abbreviated).day().hour().minute()
        formatter.timeZone = snapshot.flatMap { TimeZone(identifier: $0.timeZone) } ?? .current
        return date.formatted(formatter)
    }
}

private struct StandupThreadView: View {
    let store: Store
    let thread: StandupThread
    @Binding var reply: String
    let revoke: (String) throws -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var messages: [StandupMessage] = []
    @State private var problem: String?
    @State private var confirmingRevoke = false
    @State private var scrollToLatest = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Standup with \(thread.sender)")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(threadStatus(thread.state))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    if thread.state == "active" {
                        Text("Access ends \(expiration)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if thread.state == "active" {
                    Button("Revoke Access…") { confirmingRevoke = true }
                }
            }
            .padding(20)
            Divider()

            ScrollViewReader { scroll in
                ScrollView {
                    if messages.isEmpty {
                        ContentUnavailableView("No updates yet", systemImage: "bubble.left")
                    } else {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(messages, id: \.sequence) { message in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(message.author == "owner" ? "You" : thread.sender)
                                        .font(.headline)
                                    Text(standupDate(message.createdAt)?.formatted(date: .abbreviated, time: .shortened)
                                         ?? message.createdAt)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(verbatim: message.body)
                                        .textSelection(.enabled)
                                        .lineSpacing(3)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(message.sequence)
                            }
                            if let last = messages.last, last.sequence < thread.latestSequence {
                                Button("Load More Replies") { load() }
                            }
                        }
                        .padding(20)
                    }
                }
                .onChange(of: messages.last?.sequence) { _, last in
                    if scrollToLatest, let last {
                        scroll.scrollTo(last, anchor: .bottom)
                        scrollToLatest = false
                    }
                }
            }

            if thread.state == "active" {
                Divider()
                VStack(alignment: .trailing, spacing: 8) {
                    TextEditor(text: $reply)
                        .frame(minHeight: 75, maxHeight: 115)
                        .accessibilityLabel("Reply to standup")
                        .border(.quaternary)
                    Button {
                        send()
                    } label: {
                        Text("Send Reply")
                            .foregroundStyle(colorScheme == .dark ? Color.black : .white)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(16)
            }
        }
        .task(id: thread.latestSequence) { load() }
        .alert("Standup", isPresented: Binding(
            get: { problem != nil },
            set: { if !$0 { problem = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
        .confirmationDialog("Revoke standup access?", isPresented: $confirmingRevoke) {
            Button("Revoke Standup Access", role: .destructive) {
                do {
                    try revoke(thread.requestID)
                } catch {
                    problem = error.localizedDescription
                }
            }
        } message: {
            Text("This closes the thread to \(thread.sender).")
        }
    }

    private var expiration: String {
        standupDate(thread.expiresAt)?.formatted(date: .abbreviated, time: .shortened) ?? thread.expiresAt
    }

    private func load() {
        do {
            let incoming = try store.standupMessages(threadID: thread.id, after: messages.last?.sequence ?? 0)
            messages.append(contentsOf: incoming)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func send() {
        do {
            _ = try store.replyToStandup(threadID: thread.id, body: reply, requestID: UUID().uuidString)
            reply = ""
            scrollToLatest = true
            load()
        } catch {
            problem = error.localizedDescription
        }
    }
}

private func threadStatus(_ state: String) -> String {
    switch state {
    case "active": "Open"
    case "revoked": "Access revoked"
    case "expired": "Expired"
    default: "Unavailable"
    }
}

private func standupDate(_ value: String) -> Date? {
    if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) { return date }
    return try? Date.ISO8601FormatStyle().parse(value)
}
