import CSQLite
import Darwin
import Foundation

final class Database {
    private let handle: OpaquePointer
    private let lock = NSRecursiveLock()

    init(url: URL) throws {
        // Foundation normalizes /private/var back to /var, which SQLite rejects with NOFOLLOW.
        guard let parent = realpath(url.deletingLastPathComponent().path, nil) else {
            throw HereforthError("Could not resolve the local database directory.")
        }
        defer { free(parent) }
        let path = String(cString: parent) + "/" + url.lastPathComponent
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw HereforthError("Could not open the local database file.") }
        defer { close(fd) }
        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0 else {
            throw HereforthError("Could not set private permissions on the local database file.")
        }

        var connection: OpaquePointer?
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
              let connection else {
            sqlite3_close(connection)
            throw HereforthError("Could not open the local SQLite database.")
        }
        handle = connection
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit { sqlite3_close(handle) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func execute(_ sql: String, _ values: [String] = []) throws {
        _ = try query(sql, values) { _ in () }
    }

    func query<T>(_ sql: String, _ values: [String] = [], row: (OpaquePointer) -> T) throws -> [T] {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw error()
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let status = value.withCString {
                sqlite3_bind_text(statement, Int32(index + 1), $0, Int32(value.utf8.count), transient)
            }
            guard status == SQLITE_OK else { throw error() }
        }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(row(statement))
            case SQLITE_DONE: return rows
            default: throw error()
            }
        }
    }

    static func string(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        let count = Int(sqlite3_column_bytes(statement, index))
        return String(decoding: UnsafeBufferPointer(start: value, count: count), as: UTF8.self)
    }

    private func error() -> HereforthError {
        HereforthError("SQLite error: \(String(cString: sqlite3_errmsg(handle)))")
    }
}
