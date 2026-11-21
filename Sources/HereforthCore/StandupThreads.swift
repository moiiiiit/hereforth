import CSQLite
import Foundation

public struct StandupThread: Codable, Identifiable, Sendable {
    public let id: String
    public let sender: String
    public let state: String
    public let expiresAt: String
    public let requestID: String
    public let latestSequence: Int
}

public struct StandupMessage: Codable, Identifiable, Sendable {
    public let id: String
    public let author: String
    public let body: String
    public let createdAt: String
    public let sequence: Int
}

extension Store {
    func installStandupTables() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS standup_threads (
                id TEXT PRIMARY KEY, work_id TEXT NOT NULL UNIQUE REFERENCES work_requests(id)
            )
            """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS standup_messages (
                thread_id TEXT NOT NULL REFERENCES standup_threads(id),
                sequence INTEGER NOT NULL, id TEXT NOT NULL UNIQUE, author TEXT NOT NULL, body TEXT NOT NULL,
                request_id TEXT NOT NULL, created INTEGER NOT NULL DEFAULT (unixepoch()),
                PRIMARY KEY(thread_id, sequence), UNIQUE(thread_id, author, request_id)
            )
            """)
    }

    public func reviewStandupRequest(id: String, approvedText: String) throws -> StandupThread {
        let id = try standupUUID(id)
        guard accepts(approvedText, limit: 12_000, multiline: true) else {
            throw HereforthError("Review a standup update of up to 12,000 bytes of plain text.")
        }
        try rejectLocalCitations(approvedText)
        return try db.transaction {
            if let existing = try standupThread(whereSQL: "w.id = ?", values: [id]),
               existing.state == "active", let seed = try standupMessageRows(threadID: existing.id, after: 0).first,
               seed.body.utf8.elementsEqual(approvedText.utf8) {
                return existing
            }
            let approved = try db.query("""
                UPDATE work_requests SET state = 'fulfilled', grant_expires = unixepoch() + 604800,
                    receipt = 'Opened a private standup thread until '
                      || strftime('%Y-%m-%dT%H:%M:%SZ', unixepoch() + 604800, 'unixepoch') || '.'
                WHERE id = ? AND requests_standup = 1 AND state = 'pending' RETURNING id
                """, [id]) { Database.string($0, 0) }
            guard !approved.isEmpty else { throw HereforthError("This standup request is no longer pending.") }
            let threadID = UUID().uuidString
            try db.execute("INSERT INTO standup_threads (id, work_id) VALUES (?, ?)", [threadID, id])
            _ = try addStandupMessage(threadID: threadID, author: "owner", body: approvedText, requestID: UUID().uuidString)
            guard let thread = try standupThread(whereSQL: "t.id = ?", values: [threadID]) else {
                throw HereforthError("Could not create the standup thread.")
            }
            return thread
        }
    }

    public func standupThreads() throws -> [StandupThread] {
        try db.query(Self.standupSelection + " ORDER BY t.rowid DESC", row: standupThreadRow)
    }

    public func peerStandupThreads(sender: String, offset: Int = 0) throws -> [StandupThread] {
        guard offset >= 0 else { throw HereforthError("Use a nonnegative offset.") }
        return try db.query(Self.standupSelection + " WHERE w.sender = ? AND " + Self.activeStandup +
                            " ORDER BY t.rowid DESC LIMIT 51 OFFSET CAST(? AS INTEGER)",
                            [sender, String(offset)], row: standupThreadRow)
    }

    public func standupMessages(threadID: String, after: Int = 0) throws -> [StandupMessage] {
        let id = try standupUUID(threadID)
        return try db.transaction(write: false) {
            guard try standupThread(whereSQL: "t.id = ?", values: [id]) != nil else {
                throw HereforthError("This standup thread is unavailable.")
            }
            return try standupMessageRows(threadID: id, after: after)
        }
    }

    public func peerStandupMessages(sender: String, threadID: String, after: Int = 0) throws -> [StandupMessage]? {
        let id = try standupUUID(threadID)
        return try db.transaction(write: false) {
            guard try standupThread(whereSQL: "t.id = ? AND w.sender = ? AND " + Self.activeStandup, values: [id, sender]) != nil else {
                return nil
            }
            return try standupMessageRows(threadID: id, after: after)
        }
    }

    public func replyToStandup(threadID: String, body: String, requestID: String) throws -> StandupMessage {
        try standupReply(sender: nil, threadID: threadID, body: body, requestID: requestID)
    }

    public func replyToPeerStandup(sender: String, threadID: String, body: String, requestID: String) throws -> StandupMessage {
        try standupReply(sender: sender, threadID: threadID, body: body, requestID: requestID)
    }

    private static let activeStandup = "w.state = 'fulfilled' AND w.grant_expires > unixepoch()"

    private static let standupSelection = """
        SELECT t.id, w.sender,
               CASE WHEN \(activeStandup) THEN 'active' WHEN w.state = 'fulfilled' THEN 'expired' ELSE w.state END,
               strftime('%Y-%m-%dT%H:%M:%SZ', w.grant_expires, 'unixepoch'), w.id,
               (SELECT COALESCE(MAX(sequence), 0) FROM standup_messages WHERE thread_id = t.id)
        FROM standup_threads t JOIN work_requests w ON w.id = t.work_id
        """

    private func standupThread(whereSQL: String, values: [String]) throws -> StandupThread? {
        try db.query(Self.standupSelection + " WHERE " + whereSQL, values, row: standupThreadRow).first
    }

    private func standupThreadRow(_ row: OpaquePointer) -> StandupThread {
        StandupThread(id: Database.string(row, 0), sender: senderLabel(Database.string(row, 1)),
                      state: Database.string(row, 2), expiresAt: Database.string(row, 3),
                      requestID: Database.string(row, 4), latestSequence: Int(sqlite3_column_int64(row, 5)))
    }

    private static let standupMessageColumns = """
        id, author, body, strftime('%Y-%m-%dT%H:%M:%SZ', created, 'unixepoch'), sequence
        """

    private func standupMessageRows(threadID: String, after: Int) throws -> [StandupMessage] {
        guard after >= 0 else { throw HereforthError("Use a nonnegative message cursor.") }
        return try db.query("""
            SELECT \(Self.standupMessageColumns)
            FROM standup_messages WHERE thread_id = ? AND sequence > CAST(? AS INTEGER)
            ORDER BY sequence LIMIT 51
            """, [threadID, String(after)], row: standupMessageRow)
    }

    private func standupMessageRow(_ row: OpaquePointer) -> StandupMessage {
        StandupMessage(id: Database.string(row, 0), author: Database.string(row, 1),
                       body: Database.string(row, 2), createdAt: Database.string(row, 3),
                       sequence: Int(sqlite3_column_int64(row, 4)))
    }

    private func standupReply(sender: String?, threadID: String, body: String, requestID: String) throws -> StandupMessage {
        let id = try standupUUID(threadID)
        let requestID = try standupUUID(requestID)
        guard accepts(body, limit: 4_000, multiline: true) else {
            throw HereforthError("Enter a reply of up to 4,000 bytes of plain text.")
        }
        try rejectLocalCitations(body)
        return try db.transaction {
            var predicate = "t.id = ? AND " + Self.activeStandup
            var values = [id]
            if let sender {
                predicate += " AND w.sender = ?"
                values.append(sender)
            }
            guard try standupThread(whereSQL: predicate, values: values) != nil else {
                throw HereforthError("This standup thread is unavailable.")
            }
            return try addStandupMessage(threadID: id, author: sender == nil ? "owner" : "peer", body: body, requestID: requestID)
        }
    }

    private func addStandupMessage(threadID: String, author: String, body: String, requestID: String) throws -> StandupMessage {
        if let existing = try db.query("""
            SELECT \(Self.standupMessageColumns) FROM standup_messages
            WHERE thread_id = ? AND author = ? AND request_id = ?
            """, [threadID, author, requestID], row: standupMessageRow).first {
            guard existing.body.utf8.elementsEqual(body.utf8) else {
                throw HereforthError("This request UUID already refers to a different reply.")
            }
            return existing
        }
        let id = UUID().uuidString
        let inserted = try db.query("""
            INSERT INTO standup_messages (thread_id, sequence, id, author, body, request_id)
            SELECT ?, COALESCE(MAX(sequence), 0) + 1, ?, ?, ?, ? FROM standup_messages WHERE thread_id = ?
            RETURNING \(Self.standupMessageColumns)
            """, [threadID, id, author, body, requestID, threadID], row: standupMessageRow)
        guard let message = inserted.first else { throw HereforthError("Could not save the standup message.") }
        return message
    }

    private func standupUUID(_ value: String) throws -> String {
        guard let uuid = UUID(uuidString: value) else { throw HereforthError("Use a valid Hereforth UUID.") }
        return uuid.uuidString
    }

    private func rejectLocalCitations(_ value: String) throws {
        guard value.range(of: "hf:[0-9a-f]{64}", options: [.regularExpression, .caseInsensitive]) == nil else {
            throw HereforthError("Remove local Hereforth citations before sharing this text.")
        }
    }
}
