import CSQLite
import Foundation

public struct WeeklyEvidence: Codable, Sendable {
    public let chatID, citation, provider, title, role, date, excerpt: String
    public let excerptTruncated, titleTruncated: Bool
}

public struct WeeklyChat: Codable, Identifiable, Sendable {
    public let id, title, provider, newestDate: String
    public let count: Int
    public let titleTruncated: Bool
}

public struct WeeklyContextPage: Codable, Sendable {
    public let weekStart, weekEnd, timeZone, asOf: String
    public let entries: [WeeklyEvidence]
    public let nextCursor: String?
    public let hasUndatedSources: Bool
}

public struct WeeklyInventoryPage: Codable, Sendable {
    public let weekStart, weekEnd, timeZone, asOf: String
    public let entries: [WeeklyChat]
    public let nextCursor: String?
    public let hasUndatedSources: Bool
}

private struct WeeklyPosition: Codable {
    let mode, weekStart, weekEnd, timeZone, asOf: String
    let revision: Int64
    let date, key: String

    func cursor(date: String, key: String) throws -> String {
        try JSONEncoder().encode(WeeklyPosition(mode: mode, weekStart: weekStart, weekEnd: weekEnd,
                                               timeZone: timeZone, asOf: asOf, revision: revision,
                                               date: date, key: key)).base64EncodedString()
    }
}

extension Store {
    private static let sourceSchema = """
        CREATE TABLE IF NOT EXISTS sources (
            row_id INTEGER PRIMARY KEY, citation TEXT NOT NULL UNIQUE, chat_id TEXT NOT NULL,
            provider TEXT NOT NULL, title TEXT NOT NULL, role TEXT NOT NULL, date TEXT NOT NULL, body TEXT NOT NULL
        )
        """

    func installWeeklyContext() throws {
        let columns = try db.query("PRAGMA table_info(chats)") { Database.string($0, 1) }
        if !columns.contains("source_revision") {
            try db.execute("ALTER TABLE chats ADD COLUMN source_revision TEXT NOT NULL DEFAULT ''")
        }
        try db.execute("CREATE TABLE IF NOT EXISTS library_revision (id INTEGER PRIMARY KEY, revision INTEGER NOT NULL)")
        try db.execute("INSERT OR IGNORE INTO library_revision VALUES (1, 0)")
        try db.execute(Self.sourceSchema)
        let sourceColumns = try db.query("PRAGMA table_info(sources)") { Database.string($0, 1) }
        if !sourceColumns.contains("row_id") {
            try db.execute("DROP TRIGGER IF EXISTS sources_search_insert")
            try db.execute("DROP TRIGGER IF EXISTS sources_search_delete")
            try db.execute("DROP TABLE IF EXISTS passages")
            try db.execute("ALTER TABLE sources RENAME TO sources_legacy")
            try db.execute(Self.sourceSchema)
            try db.execute("""
                INSERT INTO sources (row_id, citation, chat_id, provider, title, role, date, body)
                SELECT rowid, citation, chat_id, provider, title, role, date, body FROM sources_legacy ORDER BY rowid
                """)
            try db.execute("DROP TABLE sources_legacy")
        }
        try db.execute("CREATE INDEX IF NOT EXISTS sources_chat ON sources(chat_id)")
        try db.execute("CREATE INDEX IF NOT EXISTS sources_week ON sources(date, citation)")
        try db.execute("CREATE INDEX IF NOT EXISTS sources_chat_week ON sources(chat_id, date, citation)")

        let schema = try db.query("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'passages'") {
            Database.string($0, 0)
        }.first
        guard schema?.contains("content='sources'") != true else { return }
        try db.execute("DROP TABLE IF EXISTS passages")
        try db.execute("""
            CREATE VIRTUAL TABLE passages USING fts5(body, title, content='sources', content_rowid='rowid')
            """)
        try db.execute("INSERT INTO passages(passages) VALUES ('rebuild')")
        try db.execute("""
            CREATE TRIGGER sources_search_insert AFTER INSERT ON sources BEGIN
                INSERT INTO passages(rowid, body, title) VALUES (new.rowid, new.body, new.title);
            END
            """)
        try db.execute("""
            CREATE TRIGGER sources_search_delete AFTER DELETE ON sources BEGIN
                INSERT INTO passages(passages, rowid, body, title) VALUES ('delete', old.rowid, old.body, old.title);
            END
            """)
    }

    func markLibraryChanged() throws {
        try db.execute("UPDATE library_revision SET revision = revision + 1 WHERE id = 1")
    }

    public func weeklyContext(now: Date = Date(), timeZone: TimeZone = .current, cursor: String? = nil,
                              limit: Int = 40, byteBudget: Int = 24_000, chatID: String? = nil) throws -> WeeklyContextPage {
        guard (1...100).contains(limit), (8_192...96_000).contains(byteBudget),
              chatID == nil || currentDigest(chatID ?? "") else {
            throw HereforthError("Use a valid chat ID, a page size from 1 to 100, and an evidence budget from 8,192 to 96,000 bytes.")
        }
        return try db.transaction(write: false) {
            let position = try weeklyPosition(now: now, timeZone: timeZone, cursor: cursor, mode: "evidence:\(chatID ?? "")")
            let scope = chatID == nil ? "" : "AND chat_id = ?"
            let after = position.key.isEmpty ? "" : "AND (date, citation) < (?, ?)"
            let values = weeklyArguments(position) + (chatID.map { [$0] } ?? []) + [String(limit + 1)]
            let matches = try db.query("""
                SELECT chat_id, citation, provider, role, date,
                       substr(CAST(title AS BLOB), 1, 240), length(CAST(title AS BLOB)) > 240,
                       substr(CAST(body AS BLOB), 1, 1000), length(CAST(body AS BLOB)) > 1000
                FROM sources
                WHERE date >= ? AND date < ? AND date <= ? \(after) \(scope)
                ORDER BY date DESC, citation DESC LIMIT ?
                """, values) { row in
                WeeklyEvidence(chatID: Database.string(row, 0), citation: Database.string(row, 1),
                               provider: Database.string(row, 2), title: Self.validUTF8Prefix(Database.blob(row, 5)),
                               role: Database.string(row, 3), date: Database.string(row, 4),
                               excerpt: Self.validUTF8Prefix(Database.blob(row, 7)),
                               excerptTruncated: sqlite3_column_int(row, 8) == 1,
                               titleTruncated: sqlite3_column_int(row, 6) == 1)
            }
            let encoder = JSONEncoder()
            var entries: [WeeklyEvidence] = []
            var bytes = 2
            for match in matches.prefix(limit) {
                let entryBytes = try encoder.encode(match).count + (entries.isEmpty ? 0 : 1)
                guard bytes + entryBytes <= byteBudget else { break }
                bytes += entryBytes
                entries.append(match)
            }
            let next = matches.count > entries.count
                ? try entries.last.map { try position.cursor(date: $0.date, key: $0.citation) }
                : nil
            return WeeklyContextPage(weekStart: position.weekStart, weekEnd: position.weekEnd,
                                     timeZone: position.timeZone, asOf: position.asOf,
                                     entries: entries, nextCursor: next, hasUndatedSources: try hasUndatedSources(chatID))
        }
    }

    public func weeklyInventory(now: Date = Date(), timeZone: TimeZone = .current, cursor: String? = nil,
                                limit: Int = 40) throws -> WeeklyInventoryPage {
        guard (1...100).contains(limit) else { throw HereforthError("Use a page size from 1 to 100.") }
        return try db.transaction(write: false) {
            let position = try weeklyPosition(now: now, timeZone: timeZone, cursor: cursor, mode: "inventory")
            let after = position.key.isEmpty ? "" : "WHERE (week.newest, c.id) < (?, ?)"
            let matches = try db.query("""
                WITH week AS (
                    SELECT chat_id, count(*) AS count, max(date) AS newest
                    FROM sources WHERE date >= ? AND date < ? AND date <= ?
                    GROUP BY chat_id
                )
                SELECT c.id, c.provider, week.count, week.newest,
                       substr(CAST(c.title AS BLOB), 1, 240), length(CAST(c.title AS BLOB)) > 240
                FROM week JOIN chats c ON c.id = week.chat_id \(after)
                ORDER BY week.newest DESC, c.id DESC LIMIT ?
                """, weeklyArguments(position) + [String(limit + 1)]) { row in
                WeeklyChat(id: Database.string(row, 0), title: Self.validUTF8Prefix(Database.blob(row, 4)),
                           provider: Database.string(row, 1), newestDate: Database.string(row, 3),
                           count: Int(sqlite3_column_int64(row, 2)), titleTruncated: sqlite3_column_int(row, 5) == 1)
            }
            let entries = Array(matches.prefix(limit))
            let next = matches.count > entries.count
                ? try entries.last.map { try position.cursor(date: $0.newestDate, key: $0.id) }
                : nil
            return WeeklyInventoryPage(weekStart: position.weekStart, weekEnd: position.weekEnd,
                                       timeZone: position.timeZone, asOf: position.asOf,
                                       entries: entries, nextCursor: next, hasUndatedSources: try hasUndatedSources(nil))
        }
    }

    private func weeklyPosition(now: Date, timeZone: TimeZone, cursor: String?, mode: String) throws -> WeeklyPosition {
        let revision = try db.query("SELECT revision FROM library_revision WHERE id = 1") { sqlite3_column_int64($0, 0) }.first ?? 0
        let formatter = ISO8601DateFormatter()
        if let cursor {
            guard cursor.utf8.count <= 2_048, let data = Data(base64Encoded: cursor),
                  let position = try? JSONDecoder().decode(WeeklyPosition.self, from: data), position.mode == mode,
                  let zone = TimeZone(identifier: position.timeZone), let asOf = formatter.date(from: position.asOf),
                  formatter.string(from: asOf) == position.asOf,
                  let week = weeklyInterval(now: asOf, timeZone: zone),
                  formatter.string(from: week.start) == position.weekStart,
                  formatter.string(from: week.end) == position.weekEnd,
                  ((mode == "inventory" && currentDigest(position.key))
                   || (mode != "inventory" && position.key.hasPrefix("hf:") && currentDigest(String(position.key.dropFirst(3))))),
                  position.date >= position.weekStart, position.date < position.weekEnd, position.date <= position.asOf else {
                throw HereforthError("Use a valid cursor from this weekly context view.")
            }
            guard position.revision == revision else {
                throw HereforthError("The library changed. Start a new weekly context page.")
            }
            return position
        }
        guard let week = weeklyInterval(now: now, timeZone: timeZone) else {
            throw HereforthError("Could not determine the local calendar week.")
        }
        return WeeklyPosition(mode: mode, weekStart: formatter.string(from: week.start), weekEnd: formatter.string(from: week.end),
                              timeZone: timeZone.identifier, asOf: formatter.string(from: now), revision: revision, date: "", key: "")
    }

    private func weeklyInterval(now: Date, timeZone: TimeZone) -> DateInterval? {
        guard now.timeIntervalSince1970.isFinite, abs(now.timeIntervalSince1970) < 250_000_000_000 else { return nil }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        return calendar.dateInterval(of: .weekOfYear, for: now)
    }

    private func weeklyArguments(_ position: WeeklyPosition) -> [String] {
        [position.weekStart, position.weekEnd, position.asOf] + (position.key.isEmpty ? [] : [position.date, position.key])
    }

    private func hasUndatedSources(_ chatID: String?) throws -> Bool {
        let match = chatID == nil ? "" : "AND chat_id = ?"
        return try !db.query("SELECT 1 FROM sources WHERE date = '' \(match) LIMIT 1", chatID.map { [$0] } ?? []) { _ in
            true
        }.isEmpty
    }

    private func currentDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func validUTF8Prefix(_ bytes: Data) -> String {
        for dropped in 0...min(3, bytes.count) {
            if let text = String(data: bytes.dropLast(dropped), encoding: .utf8) { return text }
        }
        return ""
    }
}
