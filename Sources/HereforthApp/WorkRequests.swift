import HereforthCore
import SwiftUI

struct WorkRequests: View {
    let requests: [WorkRequest]
    let briefs: [Brief]
    let previewDraft: (String, String) throws -> WorkRequestPreview
    let review: (String, Bool, WorkRequestPreview?) throws -> Void
    let revoke: (String) throws -> Void

    @State private var selectedCategory: WorkCategory?
    @State private var selection: WorkRequest.ID?

    private var visibleRequests: [WorkRequest] {
        guard let selectedCategory else { return requests }
        return requests.filter { WorkCategory($0.category) == selectedCategory }
    }

    private var pending: Int {
        visibleRequests.lazy.filter { $0.state == "pending" }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Work Requests")
                        .font(.title.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    if !visibleRequests.isEmpty {
                        Text("\(pending) pending")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !requests.isEmpty {
                    Picker("Filter by Category", selection: $selectedCategory) {
                        Text("All Categories").tag(nil as WorkCategory?)
                        ForEach(WorkCategory.allCases, id: \.self) { category in
                            Text(category.label).tag(Optional(category))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Show work requests in the selected category")
                }
            }
            .padding(24)
            Divider()

            if requests.isEmpty {
                ContentUnavailableView {
                    Label("No work requests", systemImage: "checklist")
                } description: {
                    Text("Requests addressed to you appear here, even after the sender’s session ends.")
                }
            } else if visibleRequests.isEmpty {
                ContentUnavailableView {
                    Label("No requests in this category", systemImage: "line.3.horizontal.decrease.circle")
                } actions: {
                    Button("Show All Requests") { selectedCategory = nil }
                }
            } else {
                HSplitView {
                    List(selection: $selection) {
                        ForEach(visibleRequests) { request in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: request.body.trimmingCharacters(in: .whitespacesAndNewlines))
                                    .fontWeight(.medium)
                                Text("\(request.sender) · \(WorkCategory(request.category).label)")
                                    .foregroundStyle(.secondary)
                                Text(workStatus(request.state))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .lineLimit(1)
                            .padding(.vertical, 3)
                            .accessibilityElement(children: .combine)
                            .tag(request.id)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .frame(minWidth: 155, idealWidth: 205, maxWidth: 300)

                    if let request = visibleRequests.first(where: { $0.id == selection }) {
                        WorkRequestDetail(
                            request: request, briefs: briefs, previewDraft: previewDraft, review: review, revoke: revoke
                        )
                        .id(request.id)
                        .frame(minWidth: 375)
                    } else {
                        ContentUnavailableView("Select a work request", systemImage: "list.bullet.rectangle")
                            .frame(minWidth: 375)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: visibleRequests.map(\.id), initial: true) { _, ids in
            if let selection, ids.contains(selection) { return }
            selection = (visibleRequests.first { $0.state == "pending" } ?? visibleRequests.first)?.id
        }
    }
}

private struct WorkRequestDetail: View {
    let request: WorkRequest
    let briefs: [Brief]
    let previewDraft: (String, String) throws -> WorkRequestPreview
    let review: (String, Bool, WorkRequestPreview?) throws -> Void
    let revoke: (String) throws -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedDraftID: Brief.ID?
    @State private var preview: WorkRequestPreview?
    @State private var errorMessage: String?
    @State private var confirmingRevoke = false

    private var pending: Bool { request.state == "pending" }
    private var canGrantBrief: Bool { request.requestsBrief }

    private var availableBriefs: [Brief] {
        guard let requestedID = request.briefID else { return briefs }
        return briefs.filter { $0.id == requestedID }
    }

    private var draftID: String? { request.briefID ?? selectedDraftID }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(WorkCategory(request.category).label)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("From \(request.sender)")
                    .textSelection(.enabled)
                Text(workStatus(request.state))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let preview, pending {
                        grantPreview(preview)
                    } else {
                        Text("Request")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        Text(verbatim: request.body)
                            .textSelection(.enabled)

                        if !request.receipt.isEmpty {
                            Divider()
                            Text("Receipt")
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            Text(verbatim: request.receipt)
                                .textSelection(.enabled)
                        } else if pending && canGrantBrief {
                            Divider()
                            draftPicker
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .id(preview?.digest)

            if pending || request.state == "fulfilled" {
                Divider()
                requestActions
                    .padding(16)
            }
        }
        .alert("Work Requests", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Revoke draft read access?", isPresented: $confirmingRevoke) {
            Button("Revoke Read Access", role: .destructive) { revokeGrant() }
        } message: {
            Text("This stops future reads by \(request.sender).")
        }
    }

    private var draftPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hereforth draft to share")
                .font(.headline)
            if let requestedID = request.briefID {
                Text(availableBriefs.first?.title ?? "The requested draft is unavailable on this Mac.")
                Text(requestedID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel("Requested draft ID \(requestedID)")
            } else if availableBriefs.isEmpty {
                Text("Ask your assistant to create a local draft before granting read access.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Local Draft", selection: $selectedDraftID) {
                    Text("Choose a draft").tag(nil as Brief.ID?)
                    ForEach(availableBriefs) { brief in
                        Text("\(brief.title) — \(brief.recipient)").tag(Optional(brief.id))
                    }
                }
                .labelsHidden()
            }
        }
    }

    private func grantPreview(_ preview: WorkRequestPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Back to Request") { self.preview = nil }
            Text(preview.title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Read access for \(preview.sender)")
                .fontWeight(.medium)
                .textSelection(.enabled)
            Text("Read-only · This version · 7 days")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Version \(preview.digest)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Divider()
            Text(verbatim: preview.markdown)
                .textSelection(.enabled)
                .lineSpacing(3)
        }
    }

    private var requestActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if pending && !canGrantBrief {
                Text("Record that you reviewed this request. Carry out any follow-up through your organization’s process.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if request.state == "fulfilled" {
                    Button("Revoke Read Access…") { confirmingRevoke = true }
                } else {
                    Button("Decline") { recordDecision(approve: false) }
                    if canGrantBrief {
                        if preview != nil {
                            primaryButton("Grant Read Access") { recordDecision(approve: true) }
                        } else {
                            primaryButton("Review Draft") { loadPreview() }
                                .disabled(!availableBriefs.contains { $0.id == draftID })
                        }
                    } else {
                        primaryButton("Mark Reviewed") { recordDecision(approve: true) }
                    }
                }
            }
        }
    }

    private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .foregroundStyle(colorScheme == .dark ? Color.black : .white)
        }
        .buttonStyle(.borderedProminent)
    }

    private func loadPreview() {
        guard let draftID else { return }
        do {
            preview = try previewDraft(request.id, draftID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func recordDecision(approve: Bool) {
        do {
            try review(request.id, approve, approve ? preview : nil)
            preview = nil
        } catch {
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    private func revokeGrant() {
        do {
            try revoke(request.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum WorkCategory: String, CaseIterable {
    case it, security, dataAccess = "data_access", vendor, other

    init(_ rawValue: String) {
        self = Self(rawValue: rawValue) ?? .other
    }

    var label: String {
        switch self {
        case .it: "IT"
        case .security: "Security"
        case .dataAccess: "Data access"
        case .vendor: "Vendor"
        case .other: "Other"
        }
    }
}

private func workStatus(_ state: String) -> String {
    switch state {
    case "pending": "Pending review"
    case "reviewed": "Reviewed"
    case "declined": "Declined"
    case "fulfilled": "Fulfilled · Read access granted"
    case "revoked": "Read access revoked"
    case "expired": "Read access expired"
    default: "Unavailable"
    }
}
