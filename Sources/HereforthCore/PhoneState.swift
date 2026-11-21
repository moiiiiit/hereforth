import Foundation

public struct OwnerTask: Codable, Identifiable, Sendable {
    public let id, client, kind, prompt, state, createdAt, updatedAt: String
}

public struct PhoneHandoff: Sendable {
    public let id, briefID, title, markdown, peer, sessionID, sessionLabel, digest, state: String
    public let receipt: String?
    public let destinationKey: String
}

extension Store {
    func installPhoneTables() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS owner_tasks (
                id TEXT PRIMARY KEY, client TEXT NOT NULL, kind TEXT NOT NULL, prompt TEXT NOT NULL,
                state TEXT NOT NULL DEFAULT 'pending_review',
                created INTEGER NOT NULL DEFAULT (unixepoch()), updated INTEGER NOT NULL DEFAULT (unixepoch())
            )
            """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS phone_handoffs (
                id TEXT PRIMARY KEY, brief_id TEXT NOT NULL, title TEXT NOT NULL,
                markdown TEXT NOT NULL, peer TEXT NOT NULL, session_id TEXT NOT NULL,
                session_label TEXT NOT NULL, destination_key TEXT NOT NULL, digest TEXT NOT NULL,
                state TEXT NOT NULL DEFAULT 'prepared', receipt TEXT,
                created INTEGER NOT NULL DEFAULT (unixepoch())
            )
            """)
    }

    public func queueOwnerTask(requestID: String, client: String, kind: String, prompt: String) throws -> OwnerTask {
        let id = try phoneUUID(requestID)
        guard ["codex", "claude"].contains(client), ["text", "computer"].contains(kind),
              accepts(prompt, limit: 8_000, multiline: true) else {
            throw HereforthError("Choose Claude or Codex and enter a task description up to 8,000 bytes.")
        }
        return try db.transaction {
            if let task = try ownerTaskRows("WHERE id = ?", [id]).first {
                guard task.client == client, task.kind == kind, task.prompt.utf8.elementsEqual(prompt.utf8) else {
                    throw HereforthError("This request ID already belongs to a different task.")
                }
                return task
            }
            try db.execute("INSERT INTO owner_tasks (id, client, kind, prompt) VALUES (?, ?, ?, ?)", [id, client, kind, prompt])
            return try requiredTask(id)
        }
    }

    public func ownerTasks() throws -> [OwnerTask] {
        try ownerTaskRows("ORDER BY rowid DESC LIMIT 200")
    }

    public func ownerTask(id: String) throws -> OwnerTask {
        try requiredTask(phoneUUID(id))
    }

    public func reviewOwnerTask(id: String, approve: Bool) throws -> OwnerTask {
        let id = try phoneUUID(id)
        let desired = approve ? "approved" : "declined"
        return try db.transaction {
            let existing = try requiredTask(id)
            if existing.state == desired { return existing }
            guard existing.state == "pending_review" else { throw HereforthError("This task has already been reviewed.") }
            try db.execute("UPDATE owner_tasks SET state = ?, updated = unixepoch() WHERE id = ?", [desired, id])
            return try requiredTask(id)
        }
    }

    public func preparePhoneHandoff(briefID: String, peer: String, sessionID: String, sessionLabel: String,
                                    destinationKey: String, requestID: String) throws -> PhoneHandoff {
        let id = try phoneUUID(requestID)
        let briefID = try phoneUUID(briefID)
        return try db.transaction {
            if let prior = try phoneHandoffRows(id).first {
                guard prior.briefID == briefID, prior.peer == peer, prior.sessionID == sessionID,
                      prior.destinationKey == destinationKey else {
                    throw HereforthError("This preview ID already belongs to a different delivery.")
                }
                return prior
            }
            let brief = try handoffBrief(briefID)
            guard accepts(brief.markdown, limit: 4_000, multiline: true) else {
                throw HereforthError("This brief exceeds the session handoff limit of 4,000 bytes or contains unsupported control characters.")
            }
            let revision = digest("phone-handoff-v1", id, briefID, brief.title, brief.markdown, peer, sessionID, sessionLabel, destinationKey)
            try db.execute("""
                INSERT INTO phone_handoffs (id, brief_id, title, markdown, peer, session_id, session_label, destination_key, digest)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [id, briefID, brief.title, brief.markdown, peer, sessionID, sessionLabel, destinationKey, revision])
            return try phoneHandoff(id)
        }
    }

    public func phoneHandoff(_ id: String) throws -> PhoneHandoff {
        guard let draft = try phoneHandoffRows(phoneUUID(id)).first else { throw HereforthError("This handoff preview is unavailable.") }
        return draft
    }

    public func startPhoneHandoff(id: String, digest: String, destinationKey: String) throws -> PhoneHandoff {
        try db.transaction {
            let preview = try phoneHandoff(id)
            guard preview.digest == digest, preview.destinationKey == destinationKey else {
                throw HereforthError("The handoff preview or paired destination changed. Review a new preview.")
            }
            if preview.state == "prepared" {
                let source = try handoffBrief(preview.briefID)
                guard source.markdown.utf8.elementsEqual(preview.markdown.utf8),
                      source.title.utf8.elementsEqual(preview.title.utf8) else {
                    throw HereforthError("The brief changed. Review a new handoff preview.")
                }
                let started = try db.query("""
                    UPDATE phone_handoffs SET state = 'sending' WHERE id = ? AND created > unixepoch() - 900
                    RETURNING id
                    """, [preview.id]) { Database.string($0, 0) }
                guard !started.isEmpty else { throw HereforthError("This preview expired. Review a new handoff preview.") }
            }
            return try phoneHandoff(preview.id)
        }
    }

    public func recordPhoneHandoffDelivery(id: String, receipt: String) throws -> PhoneHandoff {
        guard UUID(uuidString: receipt) != nil else { throw HereforthError("The recipient did not return a valid delivery receipt.") }
        return try db.transaction {
            let preview = try phoneHandoff(id)
            if preview.state == "sent", preview.receipt == receipt { return preview }
            guard preview.state == "sending" else { throw HereforthError("The handoff has no matching send in progress.") }
            try db.execute("UPDATE phone_handoffs SET state = 'sent', receipt = ? WHERE id = ?", [receipt, preview.id])
            return try phoneHandoff(preview.id)
        }
    }

    public func handoffBrief(_ id: String) throws -> Brief {
        let id = try phoneUUID(id)
        guard let brief = try db.query("SELECT id, title, recipient, markdown FROM briefs WHERE id = ?", [id], row: {
            Brief(id: Database.string($0, 0), title: Database.string($0, 1), recipient: Database.string($0, 2), markdown: Database.string($0, 3))
        }).first else { throw HereforthError("This brief is unavailable.") }
        return brief
    }

    private func phoneUUID(_ value: String) throws -> String {
        guard value.utf8.count == 36, let id = UUID(uuidString: value) else { throw HereforthError("Use a valid request UUID.") }
        return id.uuidString
    }

    private func requiredTask(_ id: String) throws -> OwnerTask {
        guard let task = try ownerTaskRows("WHERE id = ?", [id]).first else { throw HereforthError("This task is unavailable.") }
        return task
    }

    private func ownerTaskRows(_ filter: String, _ values: [String] = []) throws -> [OwnerTask] {
        try db.query("""
            SELECT id, client, kind, prompt, state, strftime('%Y-%m-%dT%H:%M:%SZ', created, 'unixepoch'),
            strftime('%Y-%m-%dT%H:%M:%SZ', updated, 'unixepoch') FROM owner_tasks \(filter)
            """, values) {
            OwnerTask(id: Database.string($0, 0), client: Database.string($0, 1), kind: Database.string($0, 2),
                      prompt: Database.string($0, 3), state: Database.string($0, 4),
                      createdAt: Database.string($0, 5), updatedAt: Database.string($0, 6))
        }
    }

    private func phoneHandoffRows(_ id: String) throws -> [PhoneHandoff] {
        try db.query("""
            SELECT id, brief_id, title, markdown, peer, session_id, session_label, digest, state, receipt, destination_key
            FROM phone_handoffs WHERE id = ?
            """, [id]) {
            let receipt = Database.string($0, 9)
            return PhoneHandoff(id: Database.string($0, 0), briefID: Database.string($0, 1), title: Database.string($0, 2),
                                markdown: Database.string($0, 3), peer: Database.string($0, 4), sessionID: Database.string($0, 5),
                                sessionLabel: Database.string($0, 6), digest: Database.string($0, 7), state: Database.string($0, 8),
                                receipt: receipt.isEmpty ? nil : receipt, destinationKey: Database.string($0, 10))
        }
    }
}
