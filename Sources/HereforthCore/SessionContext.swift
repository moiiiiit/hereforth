import CSQLite
import Darwin
import Foundation

public struct SharedSession: Codable, Identifiable, Sendable {
    public let id: String
    public let label: String
}

public struct ContextOffer: Codable, Identifiable, Sendable {
    public let id: String
    public let sender: String
    public let sessionID: String
    public let sessionLabel: String
    public let body: String
    public let state: String
}

extension Store {
    func installSessionContextTables() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS shared_sessions (
                id TEXT PRIMARY KEY, label TEXT NOT NULL, pid INTEGER NOT NULL, process_start TEXT NOT NULL,
                ended INTEGER NOT NULL DEFAULT 0, lease_until INTEGER NOT NULL DEFAULT 0
            )
            """)
        let sessionColumns = try db.query("PRAGMA table_info(shared_sessions)") { Database.string($0, 1) }
        if !sessionColumns.contains("lease_until") {
            try db.execute("ALTER TABLE shared_sessions ADD COLUMN lease_until INTEGER NOT NULL DEFAULT 0")
        }
        try db.execute("""
            CREATE TABLE IF NOT EXISTS context_offers (
                id TEXT PRIMARY KEY, sender TEXT NOT NULL, session_id TEXT NOT NULL,
                session_label TEXT NOT NULL, body TEXT NOT NULL, request_id TEXT NOT NULL,
                state TEXT NOT NULL DEFAULT 'pending', created INTEGER NOT NULL DEFAULT (unixepoch()),
                UNIQUE(sender, request_id)
            )
            """)
        try db.execute("CREATE INDEX IF NOT EXISTS context_offers_delivery ON context_offers(session_id, state)")
    }

    public func publishSession(id: String, label: String, pid: Int32) throws {
        let id = try sessionKey(id)
        guard accepts(label, limit: 160, multiline: false), let started = processStart(pid) else {
            throw HereforthError("Use a short session label and a running local process.")
        }
        let published = try db.query("""
            INSERT INTO shared_sessions (id, label, pid, process_start, lease_until)
            VALUES (?, ?, ?, ?, unixepoch() + 1800)
            ON CONFLICT(id) DO UPDATE SET label = excluded.label, lease_until = excluded.lease_until
            WHERE ended = 0 AND lease_until > unixepoch()
              AND pid = excluded.pid AND process_start = excluded.process_start RETURNING id
            """, [id, label, String(pid), started]) { Database.string($0, 0) }
        guard !published.isEmpty else { throw HereforthError("This session can no longer be published.") }
    }

    public func closeSession(id: String) throws {
        let id = try sessionKey(id)
        try db.transaction { try endSession(id) }
    }

    public func publishedSessions() throws -> [SharedSession] {
        try db.transaction {
            try expireOffers()
            return try liveSessions().map(\.session)
        }
    }

    public func offerContext(sender: String, sessionID: String, body: String, requestID: String) throws -> String {
        let sessionID = try sessionKey(sessionID)
        guard accepts(sender, limit: 256, multiline: false), accepts(requestID, limit: 160, multiline: false),
              accepts(body, limit: 8_192, multiline: true) else {
            throw HereforthError("Use an identified sender and up to 8 KB of plain text.")
        }
        return try db.transaction {
            let duplicates = try db.query("""
                SELECT id, session_id, body FROM context_offers WHERE sender = ? AND request_id = ?
                """, [sender, requestID]) { (Database.string($0, 0), Database.string($0, 1), Database.string($0, 2)) }
            if let duplicate = duplicates.first {
                guard duplicate.1 == sessionID, duplicate.2.utf8.elementsEqual(body.utf8) else {
                    throw HereforthError("A request ID already refers to a different context offer.")
                }
                return duplicate.0
            }
            guard let active = try liveSessions().first(where: { $0.session.id == sessionID }) else {
                throw HereforthError("This session is no longer accepting context offers.")
            }
            let id = UUID().uuidString.lowercased()
            try db.execute("""
                INSERT INTO context_offers (id, sender, session_id, session_label, body, request_id)
                VALUES (?, ?, ?, ?, ?, ?)
                """, [id, sender, sessionID, active.session.label, body, requestID])
            return id
        }
    }

    public func contextInbox() throws -> [ContextOffer] {
        try db.transaction {
            try expireOffers()
            _ = try liveSessions()
            return try db.query("""
                SELECT id, sender, session_id, session_label, body, state
                FROM context_offers ORDER BY rowid DESC
                """, row: offerRow)
        }
    }

    public func offerStatus(sender: String, requestID: String) throws -> String? {
        guard accepts(sender, limit: 256, multiline: false), accepts(requestID, limit: 160, multiline: false) else {
            throw HereforthError("Use a valid sender and request ID.")
        }
        return try db.transaction {
            try expireOffers()
            _ = try liveSessions()
            return try db.query("""
                SELECT CASE state WHEN 'consumed' THEN 'delivered' WHEN 'stale' THEN 'expired' ELSE state END
                FROM context_offers WHERE sender = ? AND request_id = ?
                """, [sender, requestID]) { Database.string($0, 0) }.first
        }
    }

    public func reviewContext(id: String, approve: Bool) throws {
        let reviewed = try db.transaction {
            try expireOffers()
            _ = try liveSessions()
            return try db.query("""
                UPDATE context_offers SET state = ? WHERE id = ? AND state = 'pending' RETURNING id
                """, [approve ? "approved" : "declined", id]) { Database.string($0, 0) }
        }
        guard !reviewed.isEmpty else { throw HereforthError("This offer is no longer waiting for review.") }
    }

    public func takeContext(sessionID: String) throws -> [ContextOffer] {
        let sessionID = try sessionKey(sessionID)
        return try db.transaction {
            try expireOffers()
            guard try liveSessions().contains(where: { $0.session.id == sessionID && $0.pid == getpid() }) else {
                return []
            }
            try db.execute("""
                UPDATE shared_sessions SET lease_until = unixepoch() + 1800
                WHERE id = ? AND lease_until < unixepoch() + 1740
                """, [sessionID])
            let offers = try db.query("""
                SELECT id, sender, session_id, session_label, body, 'consumed'
                FROM context_offers WHERE session_id = ? AND state = 'approved' ORDER BY rowid
                """, [sessionID], row: offerRow)
            if !offers.isEmpty {
                try db.execute("""
                    UPDATE context_offers SET state = 'consumed' WHERE session_id = ? AND state = 'approved'
                    """, [sessionID])
            }
            return offers
        }
    }

    private func endSession(_ id: String) throws {
        try db.execute("UPDATE shared_sessions SET ended = 1 WHERE id = ?", [id])
        try db.execute("""
            UPDATE context_offers SET state = 'stale' WHERE session_id = ? AND state IN ('pending', 'approved')
            """, [id])
    }

    private func expireOffers() throws {
        try db.execute("""
            UPDATE context_offers SET state = 'stale'
            WHERE state IN ('pending', 'approved') AND created <= unixepoch() - 86400
            """)
    }

    private func liveSessions() throws -> [(session: SharedSession, pid: Int32)] {
        let rows = try db.query("""
            SELECT id, label, pid, process_start, lease_until > unixepoch()
            FROM shared_sessions WHERE ended = 0 ORDER BY rowid DESC
            """) { row in
            (SharedSession(id: Database.string(row, 0), label: Database.string(row, 1)),
             sqlite3_column_int(row, 2), Database.string(row, 3), sqlite3_column_int(row, 4) == 1)
        }
        var active: [(SharedSession, Int32)] = []
        for (session, pid, started, leased) in rows {
            if leased && processStart(pid) == started {
                active.append((session, pid))
            } else {
                try endSession(session.id)
            }
        }
        return active
    }

    private func processStart(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var process = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &process, size) == size,
              process.pbi_uid == geteuid(), process.pbi_status != UInt32(SZOMB) else { return nil }
        return "\(process.pbi_start_tvsec).\(process.pbi_start_tvusec)"
    }

    private func sessionKey(_ id: String) throws -> String {
        guard id.utf8.count == 36, let uuid = UUID(uuidString: id) else {
            throw HereforthError("Use a valid published session address.")
        }
        return uuid.uuidString.lowercased()
    }

    func accepts(_ value: String, limit: Int, multiline: Bool) -> Bool {
        value.utf8.count <= limit && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.unicodeScalars.allSatisfy { scalar in
                if multiline && [9, 10, 13].contains(scalar.value) { return true }
                return scalar.properties.generalCategory != .control
                    && (multiline || !CharacterSet.newlines.contains(scalar))
            }
    }

    private func offerRow(_ row: OpaquePointer) -> ContextOffer {
        ContextOffer(id: Database.string(row, 0), sender: senderLabel(Database.string(row, 1)), sessionID: Database.string(row, 2),
                     sessionLabel: Database.string(row, 3), body: Database.string(row, 4), state: Database.string(row, 5))
    }

    func senderLabel(_ identity: String) -> String {
        guard let marker = identity.range(of: " [hf-pair:", options: .backwards),
              marker.lowerBound != identity.startIndex, identity.hasSuffix("]") else { return identity }
        let fingerprint = identity[marker.upperBound...].dropLast().utf8
        guard fingerprint.count == 32, fingerprint.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return identity
        }
        return String(identity[..<marker.lowerBound])
    }
}
