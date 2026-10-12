import Foundation
import SQLite3

/// One past Lookup.
public struct HistoryEntry: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let date: Date
    public let source: LookupSource
    public let direction: Direction
    public let text: String
    public let translation: String
    public let backend: String
}

/// History of Lookups and Encounter counts, in SQLite under Application Support
/// (kept out of the Workspace so the app never races an agent editing the CSVs).
public final class HistoryStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public convenience init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(path: url.path)
    }

    private init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw BackendError.failed("Couldn't open history database at \(path)")
        }
        try execute("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS lookups (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at REAL NOT NULL,
                source TEXT NOT NULL,
                direction TEXT NOT NULL,
                text TEXT NOT NULL,
                translation TEXT NOT NULL DEFAULT '',
                backend TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS lookups_created ON lookups(created_at);
            CREATE TABLE IF NOT EXISTS encounters (
                word TEXT PRIMARY KEY,
                count INTEGER NOT NULL,
                last_seen REAL NOT NULL
            );
            """)
    }

    /// An in-memory store, for tests and as a fallback.
    public static func inMemory() throws -> HistoryStore {
        try HistoryStore(path: ":memory:")
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kandong/history.sqlite")
    }

    deinit { sqlite3_close(db) }

    // MARK: Lookups

    @discardableResult
    public func record(source: LookupSource, direction: Direction, text: String, date: Date = Date()) -> Int64 {
        locked {
            run("INSERT INTO lookups (created_at, source, direction, text) VALUES (?, ?, ?, ?)",
                [.double(date.timeIntervalSince1970), .text(source.rawValue), .text(direction.rawValue), .text(text)])
            return sqlite3_last_insert_rowid(db)
        }
    }

    public func setTranslation(id: Int64, translation: String, backend: String) {
        locked { run("UPDATE lookups SET translation = ?, backend = ? WHERE id = ?", [.text(translation), .text(backend), .int(id)]) }
    }

    public func recent(limit: Int = 200, matching search: String = "") -> [HistoryEntry] {
        locked {
            var sql = "SELECT id, created_at, source, direction, text, translation, backend FROM lookups"
            var params: [Value] = []
            if !search.isEmpty {
                sql += " WHERE text LIKE ? OR translation LIKE ?"
                params = [.text("%\(search)%"), .text("%\(search)%")]
            }
            sql += " ORDER BY created_at DESC LIMIT ?"
            params.append(.int(Int64(limit)))
            return query(sql, params) { row in
                HistoryEntry(
                    id: sqlite3_column_int64(row, 0),
                    date: Date(timeIntervalSince1970: sqlite3_column_double(row, 1)),
                    source: LookupSource(rawValue: Self.string(row, 2)) ?? .selection,
                    direction: Direction(rawValue: Self.string(row, 3)) ?? .learn,
                    text: Self.string(row, 4),
                    translation: Self.string(row, 5),
                    backend: Self.string(row, 6)
                )
            }
        }
    }

    public func delete(id: Int64) {
        locked { run("DELETE FROM lookups WHERE id = ?", [.int(id)]) }
    }

    public func prune(olderThanDays days: Int, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        locked { run("DELETE FROM lookups WHERE created_at < ?", [.double(cutoff)]) }
    }

    // MARK: Encounters

    /// Counts one Encounter for each distinct word.
    public func recordEncounters(_ words: Set<String>, date: Date = Date()) {
        locked {
            for word in words {
                run("""
                    INSERT INTO encounters (word, count, last_seen) VALUES (?, 1, ?)
                    ON CONFLICT(word) DO UPDATE SET count = count + 1, last_seen = excluded.last_seen
                    """, [.text(word), .double(date.timeIntervalSince1970)])
            }
        }
    }

    public func encounterCounts() -> [String: Int] {
        locked {
            var counts: [String: Int] = [:]
            for (word, count) in query("SELECT word, count FROM encounters", [], { row in
                (Self.string(row, 0), Int(sqlite3_column_int64(row, 1)))
            }) {
                counts[word] = count
            }
            return counts
        }
    }

    // MARK: SQLite plumbing

    private enum Value {
        case text(String)
        case int(Int64)
        case double(Double)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw BackendError.failed("History database error: \(message)")
        }
    }

    private func prepare(_ sql: String, _ params: [Value]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .int(let int): sqlite3_bind_int64(statement, index, int)
            case .double(let double): sqlite3_bind_double(statement, index, double)
            }
        }
        return statement
    }

    private func run(_ sql: String, _ params: [Value]) {
        guard let statement = prepare(sql, params) else { return }
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    private func query<T>(_ sql: String, _ params: [Value], _ map: (OpaquePointer) -> T) -> [T] {
        guard let statement = prepare(sql, params) else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append(map(statement)) }
        return rows
    }

    private static func string(_ row: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(row, column).map { String(cString: $0) } ?? ""
    }
}
