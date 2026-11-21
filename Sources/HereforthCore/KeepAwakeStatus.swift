import CSQLite
import Darwin
import Foundation

public struct KeepAwakeStatus: Codable, Sendable {
    public let appRunning: Bool
    public let active: Bool
    public let mode: String?
    public let endsAt: Date?
    public let intervalSeconds: Int?
    public let pointerState: String
}

extension Store {
    func installKeepAwakeStatusTable() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS keep_awake_status (
                id INTEGER PRIMARY KEY CHECK (id = 1), pid INTEGER NOT NULL, process_start TEXT NOT NULL,
                mode TEXT, ends_at REAL, interval_seconds INTEGER, pointer_state TEXT NOT NULL
            )
            """)
    }

    public func setKeepAwakeStatus(mode: String?, endsAt: Date?, intervalSeconds: Int?, pointerState: String) throws {
        let pid = getpid()
        guard let started = processStart(pid),
              mode == nil || mode == "system" || mode == "display",
              intervalSeconds == nil || (intervalSeconds ?? 0) > 0,
              endsAt == nil || (endsAt?.timeIntervalSince1970.isFinite == true && mode != nil),
              ["off", "enabled", "permissionRequired"].contains(pointerState) else {
            throw HereforthError("The Hereforth power status is invalid.")
        }
        try db.execute("""
            INSERT INTO keep_awake_status (id, pid, process_start, mode, ends_at, interval_seconds, pointer_state)
            VALUES (1, ?, ?, NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), ?)
            ON CONFLICT(id) DO UPDATE SET pid = excluded.pid, process_start = excluded.process_start,
                mode = excluded.mode, ends_at = excluded.ends_at, interval_seconds = excluded.interval_seconds,
                pointer_state = excluded.pointer_state
            """, [String(pid), started, mode ?? "", endsAt.map { String($0.timeIntervalSince1970) } ?? "",
                   intervalSeconds.map(String.init) ?? "", pointerState])
    }

    public func keepAwakeStatus(now: Date = Date()) throws -> KeepAwakeStatus {
        let rows: [KeepAwakeStatus] = try db.query("""
            SELECT pid, process_start, mode, ends_at, interval_seconds, pointer_state
            FROM keep_awake_status WHERE id = 1
            """) { row in
            let appRunning = processStart(sqlite3_column_int(row, 0)) == Database.string(row, 1)
            let mode = sqlite3_column_type(row, 2) == SQLITE_NULL ? nil : Database.string(row, 2)
            let endsAt = sqlite3_column_type(row, 3) == SQLITE_NULL ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(row, 3))
            let interval = sqlite3_column_type(row, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(row, 4))
            let expired = endsAt.map { $0 <= now } ?? false
            let active = appRunning && mode != nil && !expired
            return KeepAwakeStatus(appRunning: appRunning, active: active, mode: active ? mode : nil,
                                   endsAt: active ? endsAt : nil, intervalSeconds: interval,
                                   pointerState: appRunning && !expired ? Database.string(row, 5) : "off")
        }
        return rows.first ?? KeepAwakeStatus(appRunning: false, active: false, mode: nil, endsAt: nil,
                                             intervalSeconds: nil, pointerState: "off")
    }
}
