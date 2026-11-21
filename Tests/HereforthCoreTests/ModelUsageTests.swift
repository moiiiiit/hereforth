import Foundation
import XCTest
@testable import HereforthCore

final class ModelUsageTests: XCTestCase {
    func testClaudeStreamingAndSubagentCopiesAccountForRecordedRequestOnce() throws {
        try withRoots { claude, codex, kimi in
            let project = claude.appendingPathComponent("projects/synthetic")
            let morning = "2026-04-09T15:00:00.123Z"
            let partial = claudeReceipt("same-message", request: "one", stamp: morning, input: 60, output: 3, read: 30, write: 10)
            let completed = claudeReceipt("same-message", request: "one", stamp: morning, input: 60, output: 20,
                                          read: 30, write: 10, finished: true)
            let anotherRequest = claudeReceipt("same-message", request: "two", stamp: morning, input: 20, output: 7, finished: true)
            let older = claudeReceipt("yesterday", request: "older", stamp: "2026-04-08T23:00:00Z",
                                     input: 40, output: 5, finished: true)
            try write([
                ["type": "user", "message": ["content": "SYNTHETIC_PRIVATE_PROMPT_NEVER_RETURN"]],
                partial, completed, anotherRequest, older
            ], at: project.appendingPathComponent("session.jsonl"))
            try write([completed, partial], at: project.appendingPathComponent("session/subagents/agent-copy.jsonl"))
            try write([claudeReceipt("subagent-id", request: "agent-request", stamp: morning, input: 5, output: 4, finished: true)],
                      at: project.appendingPathComponent("session/subagents/agent-unique.jsonl"))
            let result = try UsageReader.read(period: .today, now: date("2026-04-09T18:00:00Z"), timeZone: utc,
                                              claudeRoot: claude, codexRoot: codex, kimiRoot: kimi)
            let usage = try XCTUnwrap(result.rows.first)
            XCTAssertEqual(result.start, "2026-04-09T00:00:00Z")
            XCTAssertEqual(usage.provider, "Claude Code")
            XCTAssertEqual(usage.requestCount, 3)
            XCTAssertEqual(usage.inputTokens, 125)
            XCTAssertEqual(usage.outputTokens, 31)
            XCTAssertEqual(usage.cacheReadTokens, 30)
            XCTAssertEqual(usage.cacheWriteTokens, 10)
            XCTAssertEqual(result.sources.first?.filesRead, 3)
            XCTAssertEqual(result.sources[1].state, "missing")
            let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
            XCTAssertFalse(encoded.contains("NEVER_RETURN"))
            XCTAssertFalse(encoded.contains(claude.path))
            let weekly = try UsageReader.read(period: .week, now: date("2026-04-09T18:00:00Z"), timeZone: utc,
                                              claudeRoot: claude, codexRoot: codex, kimiRoot: kimi)
            XCTAssertEqual(weekly.start, "2026-04-06T00:00:00Z")
            XCTAssertEqual(weekly.rows.first?.inputTokens, 165)
        }
    }

    func testCodexCumulativeSnapshotsModelChangesAndCopiedSessions() throws {
        try withRoots { claude, codex, kimi in
            let yesterday = "2026-04-08T22:00:00Z"
            let today = "2026-04-09T15:00:00Z"
            let previous = counts(50, 10, read: 5, reasoning: 2)
            let first = counts(100, 30, read: 40, reasoning: 10)
            let firstTotal = counts(150, 40, read: 45, reasoning: 12)
            let second = counts(70, 20, read: 5, reasoning: 3)
            let secondTotal = counts(220, 60, read: 50, reasoning: 15)
            let active: [Object] = [
                ["type": "session_meta", "payload": ["id": "thread-0001"]],
                ["type": "turn_context", "payload": ["model": "gpt-test-one"]],
                codexCounter(previous, previous, stamp: yesterday),
                codexCounter(firstTotal, first, stamp: today),
                codexCounter(firstTotal, first, stamp: today),
                ["type": "turn_context", "payload": ["model": "gpt-test-two"]],
                codexCounter(firstTotal, first, stamp: today),
                codexCounter(secondTotal, second, stamp: today),
                codexCounter(second, second, stamp: today)
            ]
            try write(active, at: codex.appendingPathComponent("sessions/2026/04/09/rollout-main.jsonl"))
            try write(active, at: codex.appendingPathComponent("archived_sessions/rollout-duplicate.jsonl"))
            try write([
                ["type": "session_meta", "payload": ["id": "fork-0002", "parent_thread_id": "thread-0001", "model": "gpt-test-one"]],
                codexCounter(firstTotal, first, stamp: today)
            ], at: codex.appendingPathComponent("sessions/2026/04/09/rollout-subagent.jsonl"))
            let result = try UsageReader.read(period: .today, now: date("2026-04-09T17:00:00Z"), timeZone: utc,
                                              claudeRoot: claude, codexRoot: codex, kimiRoot: kimi)
            let rows = Dictionary(uniqueKeysWithValues: result.rows.map { ($0.model, $0) })
            XCTAssertEqual(rows["gpt-test-one"]?.inputTokens, 100)
            XCTAssertEqual(rows["gpt-test-one"]?.outputTokens, 30)
            XCTAssertEqual(rows["gpt-test-one"]?.cacheReadTokens, 40)
            XCTAssertEqual(rows["gpt-test-one"]?.reasoningTokens, 10)
            XCTAssertEqual(rows["gpt-test-two"]?.inputTokens, 70)
            XCTAssertEqual(rows["gpt-test-two"]?.requestCount, 1)
            XCTAssertEqual(result.providerTotals.first?.inputTokens, 170)
            XCTAssertEqual(result.providerTotals.first?.outputTokens, 50)
            XCTAssertEqual(result.sources[1].state, "partial")
            XCTAssertEqual(result.sources[1].skippedRecords, 2)
        }
    }

    func testCodexRateWindowsComeFromLatestObservedCodexSnapshot() throws {
        try withRoots { claude, codex, kimi in
            let observed = "2026-04-09T15:00:00Z"
            let reset = try date("2026-04-09T19:00:00Z").timeIntervalSince1970
            let weeklyReset = try date("2026-04-14T15:00:00Z").timeIntervalSince1970
            func event(_ observed: String, bucket: String, percent: Double) -> Object {
                ["type": "event_msg", "timestamp": observed, "payload": [
                    "type": "token_count", "info": NSNull(), "rate_limits": [
                        "limit_id": bucket,
                        "primary": ["window_minutes": 300, "used_percent": percent, "resets_at": reset],
                        "secondary": ["window_minutes": 10_080, "used_percent": 23.5, "resets_at": weeklyReset]
                    ]
                ]]
            }
            try write([
                ["type": "session_meta", "payload": ["id": "rate-test"]],
                event("2026-04-09T14:45:00Z", bucket: "codex", percent: 8),
                event(observed, bucket: "codex", percent: 14.25),
                event("2026-04-09T15:05:00Z", bucket: "codex_other", percent: 92)
            ], at: codex.appendingPathComponent("sessions/rollout-rates.jsonl"))
            let fresh = try UsageReader.read(period: .today, now: date("2026-04-09T15:10:00Z"), timeZone: utc,
                                             claudeRoot: claude, codexRoot: codex, kimiRoot: kimi)
            XCTAssertTrue(fresh.rows.isEmpty)
            XCTAssertEqual(fresh.codexRateWindows.map(\.windowMinutes), [300, 10_080])
            XCTAssertEqual(fresh.codexRateWindows.map(\.usedPercent), [14.25, 23.5])
            XCTAssertEqual(fresh.codexRateWindows.first?.observedAt, "2026-04-09T15:00:00.000Z")
            XCTAssertEqual(fresh.codexRateWindows.first?.resetsAt, "2026-04-09T19:00:00Z")
            XCTAssertTrue(fresh.codexRateWindows.allSatisfy { !$0.stale })
            let stale = try UsageReader.read(period: .today, now: date("2026-04-09T15:46:00Z"), timeZone: utc,
                                             claudeRoot: claude, codexRoot: codex, kimiRoot: kimi)
            XCTAssertTrue(stale.codexRateWindows.allSatisfy(\.stale))
        }
    }

    func testUsageReadLimitsAreSurfacedAndDoNotHideFollowingRecords() throws {
        try withRoots { claude, codex, kimi in
            let file = claude.appendingPathComponent("projects/synthetic/fixture.jsonl")
            try write([], at: file)
            var bytes = Data(repeating: 65, count: 2 * 1_024 * 1_024 + 1)
            bytes.append(10)
            bytes.append(try JSONSerialization.data(withJSONObject: claudeReceipt(
                "later", request: "valid", stamp: "2026-04-09T14:00:00Z", input: 2, output: 3, finished: true
            )))
            try bytes.write(to: file)
            let result = try UsageReader.read(period: .month, now: date("2026-04-09T17:00:00Z"), timeZone: utc,
                                              claudeRoot: claude, codexRoot: codex, kimiRoot: kimi)
            XCTAssertEqual(result.start, "2026-04-01T00:00:00Z")
            XCTAssertEqual(result.rows.first?.inputTokens, 2)
            XCTAssertEqual(result.sources.first?.state, "partial")
            XCTAssertEqual(result.sources.first?.limited, true)
            XCTAssertEqual(result.sources.first?.skippedRecords, 1)
        }
    }

    func testInvalidLogRootIsReportedSeparatelyFromMissingLogs() throws {
        try withRoots { claude, codex, kimi in
            try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
            try Data().write(to: claude.appendingPathComponent("projects"))
            let report = try UsageReader.read(period: .today, claudeRoot: claude, codexRoot: codex, kimiRoot: kimi)
            XCTAssertEqual(report.sources.map(\.state), ["unreadable", "missing", "missing"])
            XCTAssertEqual(report.sources.first?.filesFailed, 1)
            XCTAssertTrue(report.rows.isEmpty)
        }
    }

    func testKimiUsesDurableIncrementsAcrossSessionsAndExcludesForkHistory() throws {
        try withRoots { claude, codex, kimi in
            let folder = kimi.appendingPathComponent("sessions/synthetic-workspace")
            let day = try date("2026-04-09T15:00:00Z")
            let epoch = Int64(day.timeIntervalSince1970 * 1_000)
            func usage(_ offset: Int64, input: Int, output: Int, read: Int?, agent: String = "main",
                       scope: String = "turn") -> Object {
                var counts: Object = ["inputOther": input, "output": output, "inputCacheCreation": 2,
                                      "raw": ["content": "SYNTHETIC_PRIVATE_RESPONSE"]]
                if let read { counts["inputCacheRead"] = read }
                return ["type": "usage.record", "agentId": agent, "usageScope": scope, "time": epoch + offset,
                        "model": "kimi-code/synthetic-model", "usage": counts]
            }
            let original = usage(1, input: 10, output: 5, read: 4)
            try write([
                original, original,
                ["type": "step.end", "time": epoch + 1, "usage": ["inputOther": 1000, "output": 1000]],
                usage(2, input: 1000, output: 1000, read: nil)
            ], at: folder.appendingPathComponent("main-session/agents/main/wire.jsonl"))
            try write([
                usage(1, input: 4, output: 11, read: 0, agent: "worker", scope: "prediction")
            ], at: folder.appendingPathComponent("main-session/agents/worker/wire.jsonl"))
            try write([
                original,
                ["type": "forked", "agentId": "main", "time": epoch + 2],
                usage(3, input: 1, output: 2, read: 0, scope: "session"),
                usage(4, input: 1000, output: 1000, read: 0, agent: "misplaced")
            ], at: folder.appendingPathComponent("fork-session/agents/main/wire.jsonl"))
            let malformed = folder.appendingPathComponent("partial-session/agents/main/wire.jsonl")
            try write([usage(5, input: 999, output: 999, read: 999)], at: malformed)
            var incomplete = try Data(contentsOf: malformed)
            incomplete.append(contentsOf: "\n{\"type\":\"fork".utf8)
            try incomplete.write(to: malformed)
            try write([original], at: folder.appendingPathComponent("unpublished-fork/agents/main/wire.jsonl"))
            for session in ["main-session", "fork-session", "partial-session"] {
                try Data("{}".utf8).write(to: folder.appendingPathComponent("\(session)/state.json"))
            }

            let report = try UsageReader.read(period: .today, now: day.addingTimeInterval(60), timeZone: utc,
                                              claudeRoot: claude, codexRoot: codex, kimiRoot: kimi)
            let row = try XCTUnwrap(report.rows.first)
            XCTAssertEqual(report.rows.count, 1)
            XCTAssertEqual(row.provider, "Kimi Code")
            XCTAssertEqual(row.requestCount, 3)
            XCTAssertEqual(row.inputTokens, 25)
            XCTAssertEqual(row.outputTokens, 18)
            XCTAssertEqual(row.cacheReadTokens, 4)
            XCTAssertEqual(row.cacheWriteTokens, 6)
            XCTAssertEqual(report.sources.last?.state, "partial")
            XCTAssertEqual(report.sources.last?.skippedRecords, 5)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("SYNTHETIC_PRIVATE_RESPONSE"))
        }
    }

    private var utc: TimeZone { TimeZone(secondsFromGMT: 0)! }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }

    private func withRoots(_ body: (URL, URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("claude"), directory.appendingPathComponent("codex"),
                 directory.appendingPathComponent("kimi"))
    }

    private func write(_ rows: [Object], at file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func claudeReceipt(_ message: String, request: String, stamp: String, input: Int, output: Int,
                               read: Int = 0, write: Int = 0, finished: Bool = false) -> Object {
        var response: Object = ["id": message, "model": "claude-test", "usage": [
            "input_tokens": input, "output_tokens": output,
            "cache_read_input_tokens": read, "cache_creation_input_tokens": write
        ]]
        if finished { response["stop_reason"] = "end_turn" }
        return ["type": "assistant", "timestamp": stamp, "requestId": request, "message": response]
    }

    private func counts(_ input: Int, _ output: Int, read: Int, reasoning: Int) -> Object {
        ["input_tokens": input, "output_tokens": output, "cached_input_tokens": read,
         "reasoning_output_tokens": reasoning, "total_tokens": input + output]
    }

    private func codexCounter(_ total: Object, _ last: Object, stamp: String) -> Object {
        ["type": "event_msg", "timestamp": stamp, "payload": [
            "type": "token_count", "info": ["total_token_usage": total, "last_token_usage": last]
        ]]
    }
}
