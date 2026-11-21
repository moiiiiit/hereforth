import CSQLite
import Foundation

public struct ChatInfo: Identifiable {
    public let id: String
    public let title: String
    public let provider: String
    public let count: Int
}

public struct Hit: Codable {
    public let citation: String
    public let provider: String
    public let title: String
    public let role: String
    public let date: String
    public let excerpt: String
}

public struct Brief: Identifiable {
    public let id: String
    public let title: String
    public let recipient: String
    public let markdown: String
}

public final class Store {
    let db: Database
    private static let pageSize = 8_000

    public init(directory: URL? = nil) throws {
        let directory = try directory ?? ProcessInfo.processInfo.environment["HEREFORTH_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
                .appendingPathComponent("Hereforth", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        db = try Database(url: directory.appendingPathComponent("hereforth.sqlite"))
        try db.transaction {
            try installSessionContextTables()
            try installWorkRequestsTable()
            try installVoiceNotesTable()
            try installKeepAwakeStatusTable()
            try installPhoneTables()
            try db.execute("""
                CREATE TABLE IF NOT EXISTS chats (
                    id TEXT PRIMARY KEY, provider TEXT NOT NULL, title TEXT NOT NULL, count INTEGER NOT NULL,
                    source_revision TEXT NOT NULL DEFAULT ''
                )
                """)
            try installWeeklyContext()
            try db.execute("""
                CREATE TABLE IF NOT EXISTS briefs (
                    id TEXT PRIMARY KEY, title TEXT NOT NULL, recipient TEXT NOT NULL, markdown TEXT NOT NULL
                )
                """)
        }
    }

    public func importFile(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= 512 * 1_024 * 1_024 else {
            throw HereforthError("Choose a regular transcript file up to 512 MB.")
        }
        let chats = try Importer.read(url)
        return try db.transaction {
            var changed = false
            for chat in chats {
                var seen = Set<String>()
                let passages = chat.passages.compactMap { passage -> (Passage, String)? in
                    let citation = "hf:" + digest(chat.id, passage.id, passage.role, passage.date, passage.body)
                    return seen.insert(citation).inserted ? (passage, citation) : nil
                }
                let revision = digest(chat.provider, chat.title, passages.map(\.1).joined())
                let updated = try db.query("""
                    INSERT INTO chats (id, provider, title, count, source_revision) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET provider = excluded.provider, title = excluded.title,
                    count = excluded.count, source_revision = excluded.source_revision
                    WHERE chats.source_revision <> excluded.source_revision RETURNING id
                    """, [chat.id, chat.provider, chat.title, String(passages.count), revision]) { Database.string($0, 0) }
                guard !updated.isEmpty else { continue }
                changed = true
                try clearSources(for: chat.id)
                for (passage, citation) in passages {
                    try db.execute("INSERT INTO sources (citation, chat_id, provider, title, role, date, body) VALUES (?, ?, ?, ?, ?, ?, ?)",
                                   [citation, chat.id, chat.provider, chat.title, passage.role, passage.date, passage.body])
                }
            }
            if changed { try markLibraryChanged() }
            return Set(chats.map(\.id)).count
        }
    }

    public func chats() throws -> [ChatInfo] {
        try db.query("SELECT id, title, provider, count FROM chats ORDER BY title COLLATE NOCASE, id") { row in
            ChatInfo(id: Database.string(row, 0), title: Database.string(row, 1),
                     provider: Database.string(row, 2), count: Int(sqlite3_column_int64(row, 3)))
        }
    }

    public func removeChat(_ id: String) throws {
        try db.transaction {
            try clearSources(for: id)
            let removed = try db.query("DELETE FROM chats WHERE id = ? RETURNING id", [id]) { Database.string($0, 0) }
            if !removed.isEmpty { try markLibraryChanged() }
        }
    }

    private func clearSources(for id: String) throws {
        try db.execute("DELETE FROM sources WHERE chat_id = ?", [id])
    }

    public func search(_ query: String) throws -> [Hit] {
        guard query.utf8.count <= 1_024 else { throw HereforthError("Use a shorter search query.") }
        let terms = query.split { !$0.isLetter && !$0.isNumber }
        guard !terms.isEmpty else { throw HereforthError("Enter at least one word to search.") }
        guard terms.count <= 32 else { throw HereforthError("Search supports up to 32 words.") }
        let match = terms.map { "\"\($0)\"" }.joined(separator: " OR ")
        return try db.query("""
            WITH matches AS MATERIALIZED (
                SELECT s.citation, s.chat_id, rank AS score,
                       snippet(passages, 0, '', '', ' … ', 28) AS excerpt
                FROM passages JOIN sources s ON s.rowid = passages.rowid WHERE passages MATCH ?
            ), ranked AS (
                SELECT *, row_number() OVER (PARTITION BY chat_id ORDER BY score, citation) AS position
                FROM matches
            )
            SELECT s.citation, s.provider, s.title, s.role, s.date, r.excerpt
            FROM ranked r JOIN sources s ON s.citation = r.citation
            WHERE r.position <= 2
            ORDER BY r.position, r.score, s.citation LIMIT 12
            """, [match]) { row in
            Hit(citation: Database.string(row, 0), provider: Database.string(row, 1),
                title: Database.string(row, 2), role: Database.string(row, 3), date: Database.string(row, 4),
                excerpt: String(Database.string(row, 5).prefix(1_000)))
        }
    }

    public func read(_ citation: String, offset: Int = 0) throws -> String {
        guard offset >= 0 else { throw HereforthError("Use a nonnegative source offset.") }
        let hit = try source(citation)
        let remainder = hit.excerpt.dropFirst(offset)
        guard !remainder.isEmpty else { throw HereforthError("There is no source text at that offset.") }
        let page = remainder.prefix(Self.pageSize)
        let next = remainder.count > page.count ? "\n\nNext offset: \(offset + page.count)" : ""
        let context = offset == 0 ? try adjacentContext(for: citation) : ""
        return header(hit) + context + "\n\n" + page + next
    }

    public func draft(recipient: String, title: String, decision: String, background: String,
                      nextStep: String, citations: [String]) throws -> Brief {
        for (value, limit) in [(recipient, 300), (title, 300), (decision, 4_000), (background, 8_000), (nextStep, 4_000)] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= limit else {
                throw HereforthError("Complete all brief fields and keep each within its length limit.")
            }
        }
        guard (1...8).contains(citations.count) else { throw HereforthError("Select one to eight citations.") }
        var evidence: [String] = []
        var seen = Set<String>()
        for citation in citations where seen.insert(citation).inserted {
            let hit = try source(citation)
            let excerpt = String(hit.excerpt.prefix(1_200))
            let quote = excerpt.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")
            let omitted = excerpt.count < hit.excerpt.count ? "\n> …" : ""
            evidence.append(header(hit) + "\n\n" + quote + omitted)
        }
        let markdown = """
            # \(oneLine(title))

            Prepared for \(oneLine(recipient))

            ## Decision

            \(decision)

            ## Background

            \(background)

            ## Next step

            \(nextStep)

            ## Selected sources

            \(evidence.joined(separator: "\n\n"))
            """ + "\n"
        let brief = Brief(id: UUID().uuidString, title: title, recipient: recipient, markdown: markdown)
        try db.execute("INSERT INTO briefs VALUES (?, ?, ?, ?)", [brief.id, title, recipient, markdown])
        return brief
    }

    public func briefs() throws -> [Brief] {
        try db.query("SELECT id, title, recipient, markdown FROM briefs ORDER BY rowid DESC") { row in
            Brief(id: Database.string(row, 0), title: Database.string(row, 1),
                  recipient: Database.string(row, 2), markdown: Database.string(row, 3))
        }
    }

    public func updateBrief(_ id: String, markdown: String) throws {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, markdown.utf8.count <= 128_000 else {
            throw HereforthError("Keep the reviewed Markdown between 1 byte and 128 KB.")
        }
        let updated = try db.query("UPDATE briefs SET markdown = ? WHERE id = ? RETURNING id", [markdown, id]) {
            Database.string($0, 0)
        }
        guard !updated.isEmpty else { throw HereforthError("This brief is missing from your local library.") }
    }

    private func adjacentContext(for citation: String) throws -> String {
        let excerpts = try db.query("""
            WITH target AS (
                SELECT rowid, chat_id FROM sources WHERE citation = ?
            ), adjacent AS (
                SELECT (
                    SELECT rowid FROM sources
                    WHERE chat_id = target.chat_id AND rowid < target.rowid ORDER BY rowid DESC LIMIT 1
                ) AS previous,
                (
                    SELECT rowid FROM sources
                    WHERE chat_id = target.chat_id AND rowid > target.rowid ORDER BY rowid LIMIT 1
                ) AS following FROM target
            )
            SELECT citation, provider, title, role, date, substr(body, 1, 400), length(body) > 400
            FROM sources WHERE rowid IN (SELECT previous FROM adjacent UNION SELECT following FROM adjacent)
            ORDER BY rowid
            """, [citation]) { row in
            let hit = Hit(citation: Database.string(row, 0), provider: Database.string(row, 1),
                          title: Database.string(row, 2), role: Database.string(row, 3),
                          date: Database.string(row, 4), excerpt: Database.string(row, 5))
            let suffix = sqlite3_column_int(row, 6) == 1 ? " …" : ""
            return header(hit) + "\n" + hit.excerpt + suffix
        }
        guard !excerpts.isEmpty else { return "" }
        return "\n\nNearby excerpts in the same conversation\n\n" + excerpts.joined(separator: "\n\n") + "\n\nExact passage"
    }

    private func source(_ citation: String) throws -> Hit {
        guard citation.utf8.count == 67, citation.hasPrefix("hf:"),
              citation.dropFirst(3).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw HereforthError("Copy a valid Hereforth citation from a search result.")
        }
        let hits = try db.query("SELECT provider, title, role, date, body FROM sources WHERE citation = ?", [citation]) { row in
            Hit(citation: citation, provider: Database.string(row, 0), title: Database.string(row, 1),
                role: Database.string(row, 2), date: Database.string(row, 3), excerpt: Database.string(row, 4))
        }
        guard let hit = hits.first else { throw HereforthError("This citation is missing from your local library.") }
        return hit
    }

    private func header(_ hit: Hit) -> String {
        "\(hit.citation) · \(hit.provider) · \(oneLine(hit.title)) · \(hit.role) · \(hit.date.isEmpty ? "Undated" : hit.date)"
    }

    private func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }
}
