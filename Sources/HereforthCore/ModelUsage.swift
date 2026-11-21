import CoreFoundation
import Darwin
import Foundation

public enum UsagePeriod: String, Codable, CaseIterable, Sendable {
    case today, week, month

    public var label: String {
        switch self {
        case .today: return "Today"
        case .week: return "This week"
        case .month: return "This month"
        }
    }

    fileprivate var component: Calendar.Component {
        switch self {
        case .today: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }
}

public struct UsageBreakdown: Codable, Identifiable, Sendable {
    public var id: String { provider + ":" + model }
    public let provider, model: String
    public let requestCount, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, reasoningTokens: Int64
}

public struct UsageSourceCoverage: Codable, Identifiable, Sendable {
    public var id: String { provider }
    public let provider, state: String
    public let filesRead, filesFailed, skippedRecords: Int
    public let limited: Bool
}

public struct UsageRateWindow: Codable, Identifiable, Sendable {
    public var id: Int { windowMinutes }
    public let windowMinutes: Int
    public let usedPercent: Double
    public let observedAt, resetsAt: String
    public let stale: Bool
}

public struct UsageReport: Codable, Sendable {
    public let period: UsagePeriod
    public let start, end, timeZone: String
    public let rows, providerTotals: [UsageBreakdown]
    public let sources: [UsageSourceCoverage]
    public let codexRateWindows: [UsageRateWindow]
}

public enum UsageReader {
    public static func read(period: UsagePeriod, now: Date = Date(), timeZone: TimeZone = .current,
                            claudeRoot: URL? = nil, codexRoot: URL? = nil) throws -> UsageReport {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        guard now.timeIntervalSince1970.isFinite,
              let start = calendar.dateInterval(of: period.component, for: now)?.start else {
            throw HereforthError("Couldn’t determine the local usage reporting period.")
        }
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claude = claudeRoot ?? configured(environment["CLAUDE_CONFIG_DIR"]) ?? home.appendingPathComponent(".claude")
        let codex = codexRoot ?? configured(environment["CODEX_HOME"]) ?? home.appendingPathComponent(".codex")
        let dates = UsageDates()
        let claudeScan = UsageLogScan()
        let claudeRows = ClaudeUsage.read(root: claude, scan: claudeScan, dates: dates, start: start, end: now)
        let codexScan = UsageLogScan()
        let codexUsage = CodexUsage.read(root: codex, scan: codexScan, dates: dates, start: start, end: now)
        let rows = claudeRows + codexUsage.rows
        let totals = Dictionary(grouping: rows, by: \.provider).keys.sorted().map { provider in
            let group = rows.filter { $0.provider == provider }
            func sum(_ field: KeyPath<UsageBreakdown, Int64>) -> Int64 {
                group.reduce(0) { $0 + $1[keyPath: field] }
            }
            return UsageBreakdown(provider: provider, model: "All models", requestCount: sum(\.requestCount),
                                  inputTokens: sum(\.inputTokens), outputTokens: sum(\.outputTokens),
                                  cacheReadTokens: sum(\.cacheReadTokens), cacheWriteTokens: sum(\.cacheWriteTokens),
                                  reasoningTokens: sum(\.reasoningTokens))
        }
        return UsageReport(period: period, start: dates.plain.string(from: start), end: dates.fractional.string(from: now),
                           timeZone: timeZone.identifier, rows: rows, providerTotals: totals,
                           sources: [claudeScan.coverage("Claude Code"), codexScan.coverage("Codex")],
                           codexRateWindows: codexUsage.windows)
    }

    private static func configured(_ value: String?) -> URL? {
        value.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }
}

private struct UsageDates {
    let plain = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter()

    init() { fractional.formatOptions.insert(.withFractionalSeconds) }
    func parse(_ value: Any?) -> Date? {
        guard let stamp = value as? String, stamp.utf8.count <= 48 else { return nil }
        return fractional.date(from: stamp) ?? plain.date(from: stamp)
    }
}

private struct UsageTokens: Equatable {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0
    var reasoning: Int64 = 0

    var observed: Bool { input > 0 || output > 0 }

    static func - (lhs: Self, rhs: Self) -> Self {
        Self(input: lhs.input - rhs.input, output: lhs.output - rhs.output, cacheRead: lhs.cacheRead - rhs.cacheRead,
             cacheWrite: lhs.cacheWrite - rhs.cacheWrite, reasoning: lhs.reasoning - rhs.reasoning)
    }

    var valid: Bool {
        input >= 0 && output >= 0 && cacheRead >= 0 && cacheWrite >= 0 && reasoning >= 0
            && cacheRead + cacheWrite <= input && reasoning <= output
    }

    mutating func add(_ other: Self) {
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheWrite += other.cacheWrite
        reasoning += other.reasoning
    }

    static func codex(_ value: Any?) -> Self? {
        guard let row = value as? Object, let input = token(row["input_tokens"]), let output = token(row["output_tokens"]) else {
            return nil
        }
        let values = Self(input: input, output: output, cacheRead: token(row["cached_input_tokens"]) ?? 0,
                          cacheWrite: token(row["cache_write_input_tokens"]) ?? 0,
                          reasoning: token(row["reasoning_output_tokens"]) ?? 0)
        return values.valid ? values : nil
    }

    static func claude(_ value: Any?) -> Self? {
        guard let row = value as? Object, let fresh = token(row["input_tokens"]), let output = token(row["output_tokens"]) else {
            return nil
        }
        let read = token(row["cache_read_input_tokens"]) ?? 0
        let write = token(row["cache_creation_input_tokens"]) ?? 0
        return Self(input: fresh + read + write, output: output, cacheRead: read, cacheWrite: write)
    }

    private static func token(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let tokens = Int64(number.stringValue), (0...1_000_000_000_000).contains(tokens) else { return nil }
        return tokens
    }
}

private struct UsageTotals {
    var count: Int64 = 0
    var tokens = UsageTokens()

    mutating func add(_ value: UsageTokens) {
        count += 1
        tokens.add(value)
    }
}

private func breakdown(_ totals: [String: UsageTotals], provider: String) -> [UsageBreakdown] {
    totals.sorted { $0.key < $1.key }.map { model, total in
        UsageBreakdown(provider: provider, model: model, requestCount: total.count,
                       inputTokens: total.tokens.input, outputTokens: total.tokens.output,
                       cacheReadTokens: total.tokens.cacheRead, cacheWriteTokens: total.tokens.cacheWrite,
                       reasoningTokens: total.tokens.reasoning)
    }
}

private func modelName(_ value: Any?) -> String? {
    guard let name = value as? String, (1...100).contains(name.utf8.count),
          name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
              || [45, 46, 47, 58, 95].contains($0) }), name != "<synthetic>" else { return nil }
    return name
}

private func logID(_ value: Any?) -> String? {
    guard let id = value as? String, (1...256).contains(id.utf8.count) else { return nil }
    return id
}

private enum ClaudeUsage {
    private struct Receipt {
        let date: Date
        let model: String
        let tokens: UsageTokens
        let finished: Bool

        func preferred(to old: Self) -> Bool {
            if tokens.observed != old.tokens.observed { return tokens.observed }
            if finished != old.finished { return finished }
            if tokens.output != old.tokens.output { return tokens.output > old.tokens.output }
            if tokens.input != old.tokens.input { return tokens.input > old.tokens.input }
            return date > old.date
        }
    }

    static func read(root: URL, scan: UsageLogScan, dates: UsageDates, start: Date, end: Date) -> [UsageBreakdown] {
        var receipts: [String: [String: Receipt]] = [:]
        for file in scan.files(in: [root.appendingPathComponent("projects")]) {
            scan.read(file) { record in
                guard record["type"] as? String == "assistant", let message = record["message"] as? Object,
                      message["model"] as? String != "<synthetic>" else { return }
                let request = logID(record["requestId"]) ?? logID(message["request_id"]) ?? ""
                guard let identity = logID(message["id"]) ?? (request.isEmpty ? logID(record["uuid"]) : request),
                      let tokens = UsageTokens.claude(message["usage"]), let date = dates.parse(record["timestamp"]) else {
                    scan.skippedRecords += 1
                    return
                }
                guard date <= end else { return }
                let candidate = Receipt(date: date, model: modelName(message["model"]) ?? "Unknown model",
                                        tokens: tokens, finished: message["stop_reason"] is String)
                if let old = receipts[identity]?[request], !candidate.preferred(to: old) { return }
                receipts[identity, default: [:]][request] = candidate
            }
        }
        var totals: [String: UsageTotals] = [:]
        for var requests in receipts.values {
            if requests.count == 2, let anonymous = requests.removeValue(forKey: ""), let explicit = requests.first,
               anonymous.preferred(to: explicit.value) {
                requests[explicit.key] = anonymous
            } else if requests.count > 2, requests.removeValue(forKey: "") != nil {
                scan.skippedRecords += 1
            }
            for receipt in requests.values where receipt.date >= start && receipt.date <= end {
                totals[receipt.model, default: UsageTotals()].add(receipt.tokens)
            }
        }
        return breakdown(totals, provider: "Claude Code")
    }
}

private enum CodexUsage {
    static func read(root: URL, scan: UsageLogScan, dates: UsageDates, start: Date, end: Date)
        -> (rows: [UsageBreakdown], windows: [UsageRateWindow]) {
        var totals: [String: UsageTotals] = [:]
        var seenSessions = Set<String>()
        var observed: Date?
        var windows: [UsageRateWindow] = []
        let folders = ["sessions", "archived_sessions"].map { root.appendingPathComponent($0) }
        for file in scan.files(in: folders) where file.lastPathComponent.hasPrefix("rollout-") {
            var duplicateOrCopied = false
            var sawMeta = false
            var model = "Unknown model"
            var lastTotal: UsageTokens?
            scan.read(file, shouldContinue: { !duplicateOrCopied }) { record in
                guard !duplicateOrCopied, let kind = record["type"] as? String, let data = record["payload"] as? Object else { return }
                if kind == "session_meta", !sawMeta {
                    sawMeta = true
                    let id = logID(data["id"]) ?? file.lastPathComponent
                    duplicateOrCopied = !seenSessions.insert(id).inserted
                    if !duplicateOrCopied, copiedHistory(data) {
                        scan.skippedRecords += 1
                        duplicateOrCopied = true
                    }
                    model = modelName(data["model"]) ?? model
                } else if kind == "turn_context" {
                    model = modelName(data["model"]) ?? "Unknown model"
                } else if kind == "event_msg", data["type"] as? String == "token_count", sawMeta {
                    let timestamp = dates.parse(record["timestamp"])
                    if let timestamp, timestamp <= end, timestamp > (observed ?? .distantPast) {
                        let captured = rateWindows(data["rate_limits"], observed: timestamp, now: end, dates: dates)
                        if !captured.isEmpty {
                            observed = timestamp
                            windows = captured
                        }
                    }
                    guard let info = data["info"] as? Object else { return }
                    guard let total = UsageTokens.codex(info["total_token_usage"]) else {
                        scan.skippedRecords += 1
                        return
                    }
                    let previous = lastTotal
                    lastTotal = total
                    guard previous != total, let date = timestamp else {
                        if previous != total { scan.skippedRecords += 1 }
                        return
                    }
                    guard date >= start && date <= end else { return }
                    let last = UsageTokens.codex(info["last_token_usage"])
                    let change = total - (previous ?? UsageTokens())
                    guard change.valid else {
                        scan.skippedRecords += 1
                        return
                    }
                    if let last, last.observed, change == last {
                        totals[model, default: UsageTotals()].add(last)
                    } else if let last, last.observed {
                        // A gap or reset cannot safely assign earlier counters to the current model or time.
                        totals[model, default: UsageTotals()].add(last)
                        scan.skippedRecords += 1
                    } else if change.observed, previous != nil {
                        totals[model, default: UsageTotals()].add(change)
                        scan.skippedRecords += 1
                    } else if change.observed {
                        scan.skippedRecords += 1
                    }
                }
            }
        }
        return (breakdown(totals, provider: "Codex"), windows)
    }

    private static func copiedHistory(_ meta: Object) -> Bool {
        logID(meta["forked_from_id"]) != nil || logID(meta["parent_thread_id"]) != nil
            || meta["attached_thread"] as? Bool == true
            || (meta["source"] as? Object)?["subagent"] != nil
            || meta["source"] as? String == "subagent"
    }

    private static func rateWindows(_ value: Any?, observed: Date, now: Date, dates: UsageDates) -> [UsageRateWindow] {
        guard let limits = value as? Object, limits["limit_id"] == nil || limits["limit_id"] is NSNull
                || limits["limit_id"] as? String == "codex" else { return [] }
        var windows: [Int: UsageRateWindow] = [:]
        for bucket in ["primary", "secondary"] {
            guard let window = limits[bucket] as? Object,
                  let minutes = (window["window_minutes"] ?? window["window_duration_mins"]) as? Int,
                  minutes == 300 || minutes == 10_080,
                  let number = window["used_percent"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  (0...100).contains(number.doubleValue),
                  let epoch = window["resets_at"] as? Double, epoch.isFinite, (0...253_402_300_799).contains(epoch) else { continue }
            let resets = Date(timeIntervalSince1970: epoch)
            guard resets >= observed else { continue }
            windows[minutes] = UsageRateWindow(windowMinutes: minutes, usedPercent: number.doubleValue,
                                              observedAt: dates.fractional.string(from: observed),
                                              resetsAt: dates.plain.string(from: resets),
                                              stale: now >= resets || now.timeIntervalSince(observed) >= 900)
        }
        return windows.values.sorted { $0.windowMinutes < $1.windowMinutes }
    }
}
