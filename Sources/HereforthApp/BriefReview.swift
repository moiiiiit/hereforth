import SwiftUI

struct BriefReview: View {
    let title: String
    let recipient: String
    @Binding var markdown: String
    let onExport: () -> Void

    @State private var mode: Mode = .preview

    private enum Mode: Hashable {
        case preview
        case edit
    }

    private var isEmpty: Bool {
        markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()

            switch mode {
            case .preview:
                preview
            case .edit:
                TextEditor(text: $markdown)
                    .font(.system(size: 14, design: .monospaced))
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Markdown for \(title)")
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Prepared for")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(recipient)
                    .font(.headline)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)

            Picker("Draft view", selection: $mode) {
                Text("Preview").tag(Mode.preview)
                Text("Edit Markdown").tag(Mode.edit)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Button(action: onExport) {
                Label("Export Markdown…", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isEmpty)
            .help("Save a Markdown file to share manually")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    private var preview: some View {
        Group {
            if isEmpty {
                ContentUnavailableView {
                    Label("Empty draft", systemImage: "doc.text")
                } description: {
                    Text("Add text in Edit Markdown to preview and export this draft.")
                } actions: {
                    Button("Edit Markdown") { mode = .edit }
                }
            } else {
                ScrollView {
                    Text(styledMarkdown)
                        .textSelection(.enabled)
                        .lineSpacing(4)
                        .frame(maxWidth: 660, alignment: .leading)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 28)
                        .frame(maxWidth: .infinity)
                }
                .accessibilityLabel("Preview of \(title)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var styledMarkdown: AttributedString {
        // Keep the literal source selectable while giving common Markdown lines visual hierarchy.
        let lines = markdown.components(separatedBy: "\n")
        var document = AttributedString()
        var fence: String?
        for (index, line) in lines.enumerated() {
            var span = AttributedString(line + (index < lines.count - 1 ? "\n" : ""))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fence {
                span.font = .system(size: 13, design: .monospaced)
                if trimmed.hasPrefix(marker) { fence = nil }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                span.font = .system(size: 13, design: .monospaced)
            } else if line.hasPrefix("# ") {
                span.font = .system(size: 29, weight: .semibold)
            } else if line.hasPrefix("## ") || line.hasPrefix("### ") {
                span.font = .system(size: 17, weight: .semibold)
            } else if trimmed.hasPrefix(">") {
                span.font = .system(size: 14)
                span.foregroundColor = .secondary
            } else {
                span.font = .system(size: 15)
            }
            document.append(span)
        }
        return document
    }
}
