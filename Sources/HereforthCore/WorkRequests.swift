import Foundation
import CSQLite

public enum WorkRequestCategory: String, Codable, CaseIterable, Sendable {
    case it
    case security
    case dataAccess = "data_access"
    case vendor
    case other
}

public struct WorkRequest: Codable, Identifiable, Sendable {
    public let id: String
    public let sender: String
    public let category: String
    public let body: String
    public let state: String
    public let receipt: String
    public let briefID: String?
    public let requestsBrief: Bool
    public let requestsStandup: Bool
}

public struct WorkRequestPreview: Sendable {
    public let briefID: String
    public let title: String
    public let markdown: String
    public let digest: String
    public let sender: String
}

public struct WorkRequestStatus: Codable, Sendable {
    public let id: String
    public let state: String
    public let receipt: String
}

public struct WorkRequestGrant: Codable, Sendable {
    public let briefID: String
    public let title: String
    public let markdown: String
    public let digest: String
    public let receipt: String
    public let expiresAt: String
}

extension Store {
    func installWorkRequestsTable() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS work_requests (
                id TEXT PRIMARY KEY, sender TEXT NOT NULL, request_id TEXT NOT NULL,
                category TEXT NOT NULL, body TEXT NOT NULL, requested_brief_id TEXT,
                state TEXT NOT NULL DEFAULT 'pending', receipt TEXT NOT NULL DEFAULT '',
                requests_brief INTEGER NOT NULL DEFAULT 0, requests_standup INTEGER NOT NULL DEFAULT 0,
                grant_brief_id TEXT, grant_title TEXT, grant_markdown TEXT, grant_digest TEXT, grant_expires INTEGER,
                UNIQUE(sender, request_id)
            )
            """)
        let columns = try db.query("PRAGMA table_info(work_requests)") { Database.string($0, 1) }
        if !columns.contains("requests_standup") {
            try db.execute("ALTER TABLE work_requests ADD COLUMN requests_standup INTEGER NOT NULL DEFAULT 0")
        }
        try installStandupTables()
    }

    public func submitWorkRequest(sender: String, requestID: String, category: String,
                                  body: String, briefID: String? = nil, requestsBrief: Bool = false,
                                  requestsStandup: Bool = false) throws -> String {
        let requestKey = try workRequestKey(sender: sender, requestID: requestID)
        guard let kind = WorkRequestCategory(rawValue: category), accepts(body, limit: 8_192, multiline: true) else {
            throw HereforthError("Choose a supported category and provide up to 8 KB of plain text.")
        }
        let target = try briefID.map { id in
            guard kind == .dataAccess, let uuid = UUID(uuidString: id) else {
                throw HereforthError("Only a data access request can name a brief UUID.")
            }
            return uuid.uuidString
        }
        let requestsBrief = requestsBrief || target != nil
        guard !requestsBrief || kind == .dataAccess else {
            throw HereforthError("Choose data access to request a Hereforth brief.")
        }
        guard !requestsStandup || (kind == .dataAccess && !requestsBrief) else {
            throw HereforthError("Standup access is a separate data access request.")
        }
        return try db.transaction {
            let existing = try db.query("""
                SELECT id, category, body, requested_brief_id, requests_brief, requests_standup
                FROM work_requests WHERE sender = ? AND request_id = ?
                """, [sender, requestKey]) { row in
                (id: Database.string(row, 0), category: Database.string(row, 1), body: Database.string(row, 2),
                 briefID: Database.string(row, 3), requestsBrief: sqlite3_column_int(row, 4) == 1,
                 requestsStandup: sqlite3_column_int(row, 5) == 1)
            }.first
            if let existing {
                guard existing.category == category, existing.briefID == (target ?? ""),
                      existing.requestsBrief == requestsBrief, existing.requestsStandup == requestsStandup,
                      existing.body.utf8.elementsEqual(body.utf8) else {
                    throw HereforthError("This request UUID already refers to different work.")
                }
                return existing.id
            }
            let id = UUID().uuidString
            try db.execute("""
                INSERT INTO work_requests (id, sender, request_id, category, body, requested_brief_id, requests_brief, requests_standup)
                VALUES (?, ?, ?, ?, ?, NULLIF(?, ''), ?, ?)
                """, [id, sender, requestKey, category, body, target ?? "", requestsBrief ? "1" : "0", requestsStandup ? "1" : "0"])
            return id
        }
    }

    public func workRequests() throws -> [WorkRequest] {
        try db.query(Self.workRequestSelection + " ORDER BY rowid DESC", row: workRequestRow)
    }

    public func workRequestStatus(sender: String, requestID: String) throws -> WorkRequestStatus? {
        let key = try workRequestKey(sender: sender, requestID: requestID)
        return try db.query("""
            SELECT id, \(Self.workState), \(Self.workReceipt) FROM work_requests WHERE sender = ? AND request_id = ?
            """, [sender, key]) { row in
            WorkRequestStatus(id: Database.string(row, 0), state: Database.string(row, 1), receipt: Database.string(row, 2))
        }.first
    }

    public func readWorkRequestGrant(sender: String, requestID: String) throws -> WorkRequestGrant? {
        let key = try workRequestKey(sender: sender, requestID: requestID)
        return try db.query("""
            SELECT grant_brief_id, grant_title, grant_markdown, grant_digest, receipt,
                   strftime('%Y-%m-%dT%H:%M:%SZ', grant_expires, 'unixepoch')
            FROM work_requests WHERE sender = ? AND request_id = ? AND state = 'fulfilled'
                AND grant_markdown IS NOT NULL AND grant_expires > unixepoch()
            """, [sender, key]) { row in
            WorkRequestGrant(briefID: Database.string(row, 0), title: Database.string(row, 1),
                             markdown: Database.string(row, 2), digest: Database.string(row, 3),
                             receipt: Database.string(row, 4), expiresAt: Database.string(row, 5))
        }.first
    }

    public func previewWorkRequest(id: String, briefID: String) throws -> WorkRequestPreview {
        try db.transaction {
            try grantPreview(for: workRequest(id), briefID: briefID)
        }
    }

    public func reviewWorkRequest(id: String, approve: Bool, briefID: String? = nil,
                                  digest: String? = nil) throws -> WorkRequest {
        try db.transaction {
            let request = try workRequest(id)
            if !approve {
                if request.state == "declined" { return request }
                guard request.state == "pending" else { throw resolvedWorkRequest() }
                try db.execute("UPDATE work_requests SET state = 'declined', receipt = ? WHERE id = ?",
                               ["The owner declined this request.", request.id])
            } else if request.requestsStandup {
                throw HereforthError("Review the exact update in Hereforth before opening a standup thread.")
            } else if request.requestsBrief {
                guard let briefID, let target = UUID(uuidString: briefID)?.uuidString, let digest else {
                    throw HereforthError("Select and review the exact brief before granting access.")
                }
                if request.state == "fulfilled" || request.state == "expired" {
                    let previouslyGranted = try db.query("""
                        SELECT id FROM work_requests WHERE id = ? AND grant_brief_id = ? AND grant_digest = ?
                        """, [request.id, target, digest]) { Database.string($0, 0) }
                    guard !previouslyGranted.isEmpty else { throw resolvedWorkRequest() }
                    return request
                }
                let preview = try grantPreview(for: request, briefID: target)
                guard preview.digest == digest else {
                    throw HereforthError("This brief changed since review. Open the latest revision and review it again.")
                }
                try db.execute("""
                    UPDATE work_requests SET state = 'fulfilled', grant_expires = unixepoch() + 604800,
                    receipt = 'Granted read access to one brief revision (' || ? || ') until '
                      || strftime('%Y-%m-%dT%H:%M:%SZ', unixepoch() + 604800, 'unixepoch') || '.',
                    grant_brief_id = ?, grant_title = ?, grant_markdown = ?, grant_digest = ? WHERE id = ?
                    """, [String(preview.digest.prefix(12)), preview.briefID, preview.title, preview.markdown,
                           preview.digest, request.id])
            } else {
                if request.state == "reviewed" { return request }
                guard request.state == "pending" else { throw resolvedWorkRequest() }
                try db.execute("UPDATE work_requests SET state = 'reviewed', receipt = ? WHERE id = ?",
                               ["Reviewed locally. No external action was recorded.", request.id])
            }
            return try workRequest(request.id)
        }
    }

    public func revokeWorkRequest(id: String) throws {
        try db.transaction {
            let request = try workRequest(id)
            if request.state == "revoked" || request.state == "expired" { return }
            guard request.state == "fulfilled" else {
                throw HereforthError("This request has no active grant.")
            }
            try db.execute("""
                UPDATE work_requests SET state = 'revoked', receipt = ?, grant_markdown = NULL WHERE id = ?
                """, [request.requestsStandup ? "The owner revoked access to the standup thread." : "The owner revoked this brief grant.", request.id])
        }
    }

    private static var workRequestSelection: String {
        """
        SELECT id, sender, category, body, \(workState), \(workReceipt),
               COALESCE(grant_brief_id, requested_brief_id), requests_brief, requests_standup
        FROM work_requests
        """
    }

    private static let expiredGrant = "state = 'fulfilled' AND COALESCE(grant_expires, 0) <= unixepoch()"

    private static var workState: String {
        "CASE WHEN \(expiredGrant) THEN 'expired' ELSE state END"
    }

    private static var workReceipt: String {
        "CASE WHEN \(expiredGrant) THEN receipt || ' This grant has expired.' ELSE receipt END"
    }

    private func workRequest(_ id: String) throws -> WorkRequest {
        guard let uuid = UUID(uuidString: id),
              let request = try db.query(Self.workRequestSelection + " WHERE id = ?", [uuid.uuidString],
                                         row: workRequestRow).first else {
            throw HereforthError("This work request is unavailable.")
        }
        return request
    }

    private func workRequestRow(_ row: OpaquePointer) -> WorkRequest {
        let briefID = Database.string(row, 6)
        return WorkRequest(id: Database.string(row, 0), sender: senderLabel(Database.string(row, 1)),
                           category: Database.string(row, 2), body: Database.string(row, 3),
                           state: Database.string(row, 4), receipt: Database.string(row, 5),
                           briefID: briefID.isEmpty ? nil : briefID,
                           requestsBrief: sqlite3_column_int(row, 7) == 1,
                           requestsStandup: sqlite3_column_int(row, 8) == 1)
    }

    private func workRequestKey(sender: String, requestID: String) throws -> String {
        guard accepts(sender, limit: 256, multiline: false), let uuid = UUID(uuidString: requestID) else {
            throw HereforthError("Use an identified sender and a request UUID.")
        }
        return uuid.uuidString
    }

    private func grantPreview(for request: WorkRequest, briefID: String) throws -> WorkRequestPreview {
        guard request.state == "pending" else { throw resolvedWorkRequest() }
        guard request.requestsBrief,
              let uuid = UUID(uuidString: briefID), request.briefID == nil || request.briefID == uuid.uuidString else {
            throw HereforthError("Review the exact local brief requested for data access.")
        }
        let id = uuid.uuidString
        let previews = try db.query("SELECT title, markdown FROM briefs WHERE id = ?", [id]) { row in
            let title = Database.string(row, 0)
            let markdown = Database.string(row, 1)
            return WorkRequestPreview(briefID: id, title: title, markdown: markdown,
                                      digest: digest("work-request-brief-v1", id, title, markdown), sender: request.sender)
        }
        guard let preview = previews.first else { throw HereforthError("The requested brief is unavailable locally.") }
        return preview
    }

    private func resolvedWorkRequest() -> HereforthError {
        HereforthError("This request has already been reviewed.")
    }
}
