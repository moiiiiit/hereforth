import HereforthCore
import SwiftUI

struct UsageView: View {
    @State private var period: UsagePeriod = .week
    @State private var report: UsageReport?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                }
                if let report {
                    reportBody(report)
                } else if !loading {
                    Text("Load token counts recorded by Claude Code and Codex on this Mac. Hereforth keeps the scan local and saves no transcript content.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model usage")
                .font(.largeTitle.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            HStack {
                Picker("Period", selection: $period) {
                    ForEach(UsagePeriod.allCases, id: \.self) { range in
                        Text(range.label).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 365)
                .disabled(loading)
                .onChange(of: period) {
                    report = nil
                    error = nil
                }

                Spacer()
                if loading {
                    ProgressView().controlSize(.small).accessibilityLabel("Reading local usage")
                }
                Button(report == nil ? "Load usage" : "Refresh", action: load)
                    .buttonStyle(.borderedProminent)
                    .disabled(loading)
            }
        }
    }

    private func reportBody(_ report: UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Local log coverage · \(report.timeZone)")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(report.sources) { source in
                let rows = report.rows.filter { $0.provider == source.provider }
                VStack(alignment: .leading, spacing: 8) {
                    Text(source.provider)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(coverage(source, hasUsage: !rows.isEmpty))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(rows) { row in
                        model(row)
                    }
                    if rows.count > 1, let total = report.providerTotals.first(where: { $0.provider == source.provider }) {
                        model(total)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.background, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary))
            }
            if !report.codexRateWindows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Codex limits observed in local logs").font(.headline)
                    ForEach(report.codexRateWindows) { window in
                        let name = window.windowMinutes == 300 ? "Five-hour window" : "Weekly window"
                        let percent = window.usedPercent.formatted(.number.precision(.fractionLength(0...2)))
                        Text("\(name) · \(percent)% used when observed")
                        Text("Observed \(timeDisplay(window.observedAt)) · Reported reset \(timeDisplay(window.resetsAt))\(window.stale ? " · Stale" : "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.background, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary))
            }
            Text("Cache counts are included in input tokens. Reasoning counts are included in output tokens. Usage records reflect this Mac’s available logs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func model(_ usage: UsageBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text(usage.model).font(.subheadline.weight(.medium)).textSelection(.enabled)
                Spacer()
                Text(usage.requestCount == 1 ? "1 record" : "\(usage.requestCount.formatted()) records")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                value("Input", usage.inputTokens)
                value("Output", usage.outputTokens)
                value("Cache read", usage.cacheReadTokens)
                value("Cache write", usage.cacheWriteTokens)
                if usage.provider == "Codex" { value("Reasoning", usage.reasoningTokens) }
            }
        }
        .padding(.top, 2)
    }

    private func value(_ label: String, _ count: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Text(count.formatted()).monospacedDigit()
        }
        .font(.caption)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func coverage(_ source: UsageSourceCoverage, hasUsage: Bool) -> String {
        switch source.state {
        case "missing":
            return "No local session logs found."
        case "unreadable":
            return "Couldn’t read local session logs."
        case "partial":
            var notes = [source.filesRead == 1 ? "1 file read" : "\(source.filesRead.formatted()) files read"]
            if source.filesFailed > 0 { notes.append("\(source.filesFailed.formatted()) unavailable") }
            if source.skippedRecords > 0 {
                notes.append(source.skippedRecords == 1 ? "1 record with missing detail" : "\(source.skippedRecords.formatted()) records with missing detail")
            }
            if source.limited { notes.append("scan limit reached") }
            return "Partial coverage · " + notes.joined(separator: " · ")
        default:
            if !hasUsage { return "No recorded usage in this period." }
            return source.filesRead == 1 ? "1 local file read." : "\(source.filesRead.formatted()) local files read."
        }
    }

    private func timeDisplay(_ stamp: String) -> String {
        let dates = ISO8601DateFormatter()
        dates.formatOptions.insert(.withFractionalSeconds)
        let date = dates.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? stamp
    }

    private func load() {
        let selected = period
        loading = true
        error = nil
        Task {
            defer { loading = false }
            do {
                report = try await Task.detached(priority: .userInitiated) {
                    try UsageReader.read(period: selected)
                }.value
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
