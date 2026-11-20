import HereforthCore
import SwiftUI

struct ContextInbox: View {
    let offers: [ContextOffer]
    let onReview: (String, Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: ContextOffer.ID?

    private var pendingCount: Int {
        offers.lazy.filter { $0.state == "pending" }.count
    }

    private var selectedOffer: ContextOffer? {
        offers.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Inbox")
                    .font(.title.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if pendingCount > 0 {
                    Text(pendingCount == 1 ? "1 request to review" : "\(pendingCount) requests to review")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            Divider()

            if offers.isEmpty {
                ContentUnavailableView {
                    Label("No context requests", systemImage: "tray")
                } description: {
                    Text("When a teammate offers context to one of your sessions, you can review it here before it reaches that session.")
                }
            } else {
                HSplitView {
                    List(selection: $selection) {
                        ForEach(offers) { offer in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(offer.sender)
                                    .fontWeight(.medium)
                                Text(offer.sessionLabel)
                                    .foregroundStyle(.secondary)
                                Text(status(offer))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .lineLimit(1)
                            .padding(.vertical, 3)
                            .tag(offer.id)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .frame(minWidth: 155, idealWidth: 205, maxWidth: 300)

                    if let offer = selectedOffer {
                        detail(offer)
                            .id(offer.id)
                            .frame(minWidth: 375)
                    } else {
                        ContentUnavailableView(
                            "Select a context request",
                            systemImage: "doc.text.magnifyingglass"
                        )
                        .frame(minWidth: 375)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: offers.map(\.id), initial: true) { _, ids in
            if let selection, ids.contains(selection) { return }
            selection = (offers.first { $0.state == "pending" } ?? offers.first)?.id
        }
    }

    private func detail(_ offer: ContextOffer) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                labelledValue("From", offer.sender)
                labelledValue("For session", offer.sessionLabel)
                Text(offer.sessionID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel("Destination session ID \(offer.sessionID)")
                Text(status(offer))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Suggested context")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: offer.body)
                        .textSelection(.enabled)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }

            if offer.state == "pending" {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Adding this text lets the session read it. Access and purchase decisions follow your organization’s process.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Spacer()
                        Button("Decline") { onReview(offer.id, false) }
                            .help("Keep this context out of the addressed session")
                        Button {
                            onReview(offer.id, true)
                        } label: {
                            Text("Add to Session")
                                .foregroundStyle(colorScheme == .dark ? Color.black : .white)
                        }
                        .buttonStyle(.borderedProminent)
                        .help("Make this exact text available to the addressed session")
                    }
                }
                .padding(16)
            }
        }
    }

    private func labelledValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.headline)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private func status(_ offer: ContextOffer) -> String {
        switch offer.state {
        case "pending": "Needs review"
        case "approved": "Allowed · Awaiting session"
        case "declined": "Declined"
        case "consumed": "Read by session"
        case "stale": "Session unavailable or expired"
        default: "Unavailable"
        }
    }
}
