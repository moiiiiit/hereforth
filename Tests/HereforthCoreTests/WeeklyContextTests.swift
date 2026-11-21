import CSQLite
import Foundation
import XCTest
@testable import HereforthCore

final class WeeklyContextTests: XCTestCase {
    func testWeekUsesLocalMondayAndDSTAndReportsUndatedEvidence() throws {
        try withLibrary { directory, store in
            let file = directory.appendingPathComponent("export.json")
            let export = [
                chat("decisions", [
                    message("earlier", "2026-03-02T04:59:59Z"),
                    message("monday", "2026-03-02T00:00:00-05:00"),
                    message("sunday", "2026-03-08T12:00:00Z"),
                    message("future", "2026-03-08T12:00:01Z"),
                    message("untimed", "unknown")
                ])
            ]
            try write(export, to: file)
            _ = try store.importFile(file)
            let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
            let page = try store.weeklyContext(now: date("2026-03-08T12:00:00Z"), timeZone: zone)
            XCTAssertEqual(page.weekStart, "2026-03-02T05:00:00Z")
            XCTAssertEqual(page.weekEnd, "2026-03-09T04:00:00Z")
            XCTAssertEqual(page.asOf, "2026-03-08T12:00:00Z")
            XCTAssertEqual(page.entries.map(\.excerpt), ["sunday", "monday"])
            XCTAssertTrue(page.hasUndatedSources)
            XCTAssertNil(page.nextCursor)
            let inventory = try store.weeklyInventory(now: date("2026-03-08T12:00:00Z"), timeZone: zone)
            XCTAssertEqual(inventory.entries.first?.count, 2)
            XCTAssertEqual(inventory.entries.first?.newestDate, "2026-03-08T12:00:00Z")
            XCTAssertTrue(try store.read(XCTUnwrap(page.entries.first?.citation)).contains("sunday"))
            let old = try XCTUnwrap(store.search("earlier").first)
            XCTAssertTrue(try store.read(old.citation).contains("earlier"))
        }
    }

    func testPagesInventoryAndChatScopeRemainStableAcrossIdenticalImports() throws {
        try withLibrary { directory, store in
            let file = directory.appendingPathComponent("export.json")
            let at = "2026-03-05T10:00:00Z"
            let unicode = String(repeating: "🪴µ", count: 220)
            let export = [
                chat("busy", (1...40).map { index in message("busy-\(index)", at, body: unicode) }, title: unicode),
                chat("quiet", [message("quiet", "2026-03-04T10:00:00Z")])
            ]
            try write(export, to: file)
            _ = try store.importFile(file)
            let now = try date("2026-03-06T10:00:00Z")
            let utc = TimeZone(secondsFromGMT: 0)!
            let inventory = try store.weeklyInventory(now: now, timeZone: utc, limit: 1)
            let busy = try XCTUnwrap(inventory.entries.first)
            XCTAssertEqual(busy.count, 40)
            XCTAssertTrue(busy.titleTruncated)
            let nextInventory = try store.weeklyInventory(cursor: XCTUnwrap(inventory.nextCursor), limit: 1)
            XCTAssertEqual(nextInventory.entries.first?.title, "quiet")
            XCTAssertNil(nextInventory.nextCursor)

            let first = try store.weeklyContext(now: now, timeZone: utc, limit: 100, byteBudget: 8_192, chatID: busy.id)
            XCTAssertFalse(first.entries.isEmpty)
            XCTAssertLessThan(first.entries.count, 40)
            XCTAssertTrue(first.entries.allSatisfy { $0.excerptTruncated && !$0.excerpt.contains("�") })
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(first.entries).count, 8_192)
            let firstCursor = try XCTUnwrap(first.nextCursor)
            XCTAssertThrowsError(try store.weeklyContext(cursor: firstCursor))
            _ = try store.importFile(file)

            var matches = first.entries
            var cursor = first.nextCursor
            while let current = cursor {
                let page = try store.weeklyContext(cursor: current, limit: 6, chatID: busy.id)
                XCTAssertEqual(page.asOf, first.asOf)
                matches += page.entries
                cursor = page.nextCursor
            }
            let order = matches.map(\.citation)
            XCTAssertEqual(order, order.sorted(by: >))
            XCTAssertEqual(Set(order).count, 40)

            let quiet = try XCTUnwrap(nextInventory.entries.first)
            let evidence = try store.weeklyContext(now: now, timeZone: utc, chatID: quiet.id)
            XCTAssertEqual(evidence.entries.map(\.excerpt), ["quiet"])
            try store.removeChat(quiet.id)
            XCTAssertThrowsError(try store.weeklyContext(cursor: firstCursor, chatID: busy.id))
        }
    }

    func testLegacyMigrationKeepsCitationsAndExternalFTSWorksAfterVacuum() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstChat = String(repeating: "a", count: 64)
        let secondChat = String(repeating: "b", count: 64)
        let first = "hf:" + firstChat
        let second = "hf:" + secondChat
        do {
            let legacy = try Database(url: directory.appendingPathComponent("hereforth.sqlite"))
            try legacy.execute("CREATE TABLE chats (id TEXT PRIMARY KEY, provider TEXT, title TEXT, count INTEGER)")
            try legacy.execute("""
                CREATE TABLE sources (citation TEXT PRIMARY KEY, chat_id TEXT, provider TEXT, title TEXT, role TEXT, date TEXT, body TEXT)
                """)
            try legacy.execute("CREATE VIRTUAL TABLE passages USING fts5(body,title,citation UNINDEXED,chat_id UNINDEXED)")
            for (chatID, citation, marker, rowID) in [(firstChat, first, "apple", 9), (secondChat, second, "pear", 24)] {
                try legacy.execute("INSERT INTO chats VALUES (?, 'Claude', ?, 1)", [chatID, marker])
                try legacy.execute("INSERT INTO sources VALUES (?, ?, 'Claude', ?, 'human', '2026-03-04T10:00:00Z', ?)",
                                   [citation, chatID, marker, marker])
                try legacy.execute("UPDATE sources SET rowid = ? WHERE citation = ?", [String(rowID), citation])
                try legacy.execute("INSERT INTO passages(rowid,body,title,citation,chat_id) VALUES (?, ?, ?, ?, ?)",
                                   [String(rowID), marker, marker, citation, chatID])
            }
        }
        let reopened = try Store(directory: directory)
        XCTAssertEqual(try reopened.search("apple").first?.citation, first)
        XCTAssertTrue(try reopened.read(second).contains("pear"))
        let page = try reopened.weeklyContext(now: date("2026-03-06T10:00:00Z"), timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(Set(page.entries.map(\.citation)), [first, second])
        try reopened.removeChat(firstChat)
        try reopened.db.execute("VACUUM")
        try reopened.db.execute("INSERT INTO passages(passages, rank) VALUES ('integrity-check', 1)")
        XCTAssertTrue(try reopened.search("apple").isEmpty)
        XCTAssertEqual(try reopened.search("pear").first?.citation, second)
        XCTAssertThrowsError(try reopened.read(first))
    }

    func testSyntheticWeeklyBenchmark() throws {
        guard ProcessInfo.processInfo.environment["HEREFORTH_BENCHMARK"] == "1" else { return }
        try withLibrary { directory, store in
            let file = directory.appendingPathComponent("benchmark.json")
            let now = try date("2026-11-20T22:00:00Z")
            let utc = TimeZone(secondsFromGMT: 0)!
            let formatter = ISO8601DateFormatter()
            let topics = ["analytics", "quoting", "database", "onboarding", "settlements", "support", "metrics", "capacity"]
            let history = (0..<1_100).map { formatter.string(from: now.addingTimeInterval(-Double($0 + 8) * 86_400)) }
            let week = (0..<5).map { formatter.string(from: now.addingTimeInterval(-Double($0) * 86_400)) }
            let export = (0..<6_300).map { i in
                let historical = i < 6_000
                let topic = topics[i % topics.count]
                let messages = (0..<12).map { j in
                    let timestamp = historical ? history[(i + j) % history.count] : week[(i + j) % week.count]
                    let body = """
                        The \(topic) team is reviewing milestone \(i). We agreed that \(j) should receive the follow-up \
                        after checking the draft and confirming the dependencies. Open questions include observed latency, \
                        approval scope, test coverage, and delivery timing. Keep the previous decision in the work log.
                        """
                    return message("message-\(j)", timestamp, body: body)
                }
                return chat("thread-\(i)", messages, title: "\(topic.capitalized) workstream \(i)")
            }
            try write(export, to: file)

            let start = ProcessInfo.processInfo.systemUptime
            XCTAssertEqual(try store.importFile(file), 6_300)
            let importTime = ProcessInfo.processInfo.systemUptime - start
            let before = Date().timeIntervalSince1970
            XCTAssertEqual(try store.importFile(file), 6_300)
            let reimportTime = Date().timeIntervalSince1970 - before
            var fetch: [Double] = []
            var inventory: [Double] = []
            for _ in 0..<31 {
                let start = ProcessInfo.processInfo.systemUptime
                let page = try store.weeklyContext(now: now, timeZone: utc)
                let middle = ProcessInfo.processInfo.systemUptime
                XCTAssertEqual(try store.weeklyInventory(now: now, timeZone: utc).entries.count, 40)
                let end = ProcessInfo.processInfo.systemUptime
                XCTAssertGreaterThan(page.entries.count, 0)
                XCTAssertLessThanOrEqual(page.entries.count, 40)
                XCTAssertNotNil(page.nextCursor)
                XCTAssertLessThanOrEqual(try JSONEncoder().encode(page.entries).count, 24_000)
                fetch.append((middle - start) * 1_000)
                inventory.append((end - middle) * 1_000)
            }
            let fileSize = try directory.appendingPathComponent("hereforth.sqlite").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            print(String(format: """
                Weekly benchmark: 6,300 chats / 75,600 passages (72,000 historical); SQLite %.1f MB.
                Full import %.2f s, identical reimport %.2f s. Median of 31 first-page reads: evidence %.2f ms, inventory %.2f ms.
                """, Double(fileSize) / 1_000_000, importTime, reimportTime, fetch.sorted()[15], inventory.sorted()[15]))
        }
    }

    private func date(_ value: String) throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: value)) }

    private func withLibrary(_ body: (URL, Store) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory, Store(directory: directory))
    }

    private func write(_ export: [[String: Any]], to file: URL) throws {
        try JSONSerialization.data(withJSONObject: export).write(to: file, options: .atomic)
    }

    private func chat(_ id: String, _ messages: [[String: String]], title: String? = nil) -> [String: Any] {
        ["uuid": id, "name": title ?? id, "chat_messages": messages]
    }

    private func message(_ id: String, _ date: String, body: String? = nil) -> [String: String] {
        ["uuid": id, "sender": "human", "created_at": date, "text": body ?? id]
    }
}
