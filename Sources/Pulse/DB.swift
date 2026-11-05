import Foundation
import SQLite3

private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class DB: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()

    init(path: String, readOnly: Bool = false) throws {
        guard sqlite3_open_v2(path, &handle, readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw DBError(message: "cannot open \(path)")
        }
        sqlite3_busy_timeout(handle, 2000)
        guard !readOnly else { return }
        try exec("""
            CREATE TABLE IF NOT EXISTS prs (
                repo TEXT NOT NULL, number INTEGER NOT NULL, author TEXT NOT NULL,
                created_at TEXT NOT NULL, merged_at TEXT NOT NULL, additions INTEGER NOT NULL,
                PRIMARY KEY (repo, number));
            CREATE TABLE IF NOT EXISTS issues (
                id TEXT PRIMARY KEY, identifier TEXT NOT NULL, title TEXT NOT NULL, url TEXT NOT NULL,
                creator TEXT, assignee TEXT, created_at TEXT NOT NULL, completed_at TEXT);
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS users (name TEXT PRIMARY KEY, email TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS subjects (
                id INTEGER PRIMARY KEY, project TEXT NOT NULL DEFAULT 'default', kind TEXT NOT NULL, name TEXT NOT NULL,
                aliases TEXT NOT NULL DEFAULT '[]');
            CREATE TABLE IF NOT EXISTS sources (
                id INTEGER PRIMARY KEY, project TEXT NOT NULL DEFAULT 'default', kind TEXT NOT NULL, url TEXT NOT NULL,
                title TEXT NOT NULL, author TEXT, date TEXT, excerpt TEXT, UNIQUE (project, url));
            CREATE TABLE IF NOT EXISTS facts (
                id INTEGER PRIMARY KEY, project TEXT NOT NULL DEFAULT 'default', subject_id INTEGER NOT NULL REFERENCES subjects(id),
                kind TEXT NOT NULL, text TEXT NOT NULL, observed_at TEXT NOT NULL, last_seen TEXT NOT NULL, recorded_at TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'confirmed', origin TEXT NOT NULL DEFAULT 'briefing', superseded_by INTEGER REFERENCES facts(id));
            CREATE TABLE IF NOT EXISTS fact_sources (
                fact_id INTEGER NOT NULL REFERENCES facts(id), source_id INTEGER NOT NULL REFERENCES sources(id), PRIMARY KEY (fact_id, source_id));
            CREATE INDEX IF NOT EXISTS facts_subject ON facts (subject_id, superseded_by);
            CREATE TABLE IF NOT EXISTS pending_replaces (
                fact_id INTEGER NOT NULL REFERENCES facts(id), replaces_id INTEGER NOT NULL REFERENCES facts(id), PRIMARY KEY (fact_id, replaces_id));
            """)
        if try query("SELECT 1 FROM sqlite_master WHERE name = 'facts_fts'").isEmpty {
            try exec("""
                CREATE VIRTUAL TABLE facts_fts USING fts5(text, content = 'facts', content_rowid = 'id', tokenize = 'porter unicode61');
                INSERT INTO facts_fts (facts_fts) VALUES ('rebuild');
                """)
        }
        try exec("""
            CREATE TRIGGER IF NOT EXISTS facts_fts_insert AFTER INSERT ON facts BEGIN INSERT INTO facts_fts (rowid, text) VALUES (new.id, new.text); END;
            CREATE TRIGGER IF NOT EXISTS facts_fts_update AFTER UPDATE OF text ON facts BEGIN
                INSERT INTO facts_fts (facts_fts, rowid, text) VALUES ('delete', old.id, old.text);
                INSERT INTO facts_fts (rowid, text) VALUES (new.id, new.text);
            END;
            """)
    }

    deinit { sqlite3_close(handle) }

    func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }

    @discardableResult
    func query(_ sql: String, _ args: [Any?] = []) throws -> [[Any?]] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(stmt) }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, TRANSIENT)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        var rows: [[Any?]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error() }
            rows.append((0..<sqlite3_column_count(stmt)).map { col -> Any? in
                switch sqlite3_column_type(stmt, col) {
                case SQLITE_INTEGER: Int(sqlite3_column_int64(stmt, col))
                case SQLITE_FLOAT: sqlite3_column_double(stmt, col)
                case SQLITE_TEXT: String(cString: sqlite3_column_text(stmt, col))
                default: nil
                }
            })
        }
        return rows
    }

    private func error() -> DBError { DBError(message: String(cString: sqlite3_errmsg(handle))) }

    func meta(_ key: String) -> String? {
        (try? query("SELECT value FROM meta WHERE key = ?", [key]))?.first?[0] as? String
    }

    func ids(_ key: String) -> [String] { decode(key) ?? [] }

    func decode<T: Decodable>(_ key: String) -> T? {
        meta(key).flatMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }
    }

    func set(_ value: some Encodable, _ key: String) throws {
        try setMeta(key, String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
    }

    func setMeta(_ key: String, _ value: String) throws {
        try query("INSERT OR REPLACE INTO meta VALUES (?, ?)", [key, value])
    }
}

struct DBError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

struct PRRow {
    let bucket, person: String
    let hours: Double
    let additions: Int
}

struct PrStats {
    var merged = 0
    var medianHours = 0.0
    var medianAdditions = 0.0
    var over500 = 0
}

struct Count: Equatable {
    let bucket: String
    let person: String
    let n: Int
}

struct Trends {
    var prs: [PRRow] = []
    var completed: [Count] = []
}

func median(_ values: [Double]) -> Double {
    let v = values.sorted()
    guard !v.isEmpty else { return 0 }
    return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
}

func prStats(_ rows: [PRRow]) -> [String: PrStats] {
    Dictionary(grouping: rows, by: \.bucket).mapValues { r in
        PrStats(
            merged: r.count,
            medianHours: median(r.map(\.hours)),
            medianAdditions: median(r.map { Double($0.additions) }),
            over500: r.filter { $0.additions >= 500 }.count
        )
    }
}

func displayName(_ name: String) -> String {
    guard let at = name.firstIndex(of: "@") else { return name }
    return name[..<at].capitalized
}

enum TrendRange: String, CaseIterable {
    case week = "7 days", month = "5 weeks", year = "12 months"

    func sql(_ column: String) -> String {
        switch self {
        case .week: "substr(\(column), 1, 10)"
        case .month: "date(\(column), '-6 days', 'weekday 1')"
        case .year: "substr(\(column), 1, 7)"
        }
    }

    func buckets(now: Date = Date()) -> [String] {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        switch self {
        case .week:
            f.dateFormat = "yyyy-MM-dd"
            return (0..<7).reversed().map { f.string(from: cal.date(byAdding: .day, value: -$0, to: now)!) }
        case .month:
            f.dateFormat = "yyyy-MM-dd"
            let monday = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            return (0..<5).reversed().map { f.string(from: cal.date(byAdding: .weekOfYear, value: -$0, to: monday)!) }
        case .year:
            f.dateFormat = "yyyy-MM"
            let first = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            return (0..<12).reversed().map { f.string(from: cal.date(byAdding: .month, value: -$0, to: first)!) }
        }
    }

    func label(_ key: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = self == .year ? "yyyy-MM" : "yyyy-MM-dd"
        guard let d = f.date(from: key) else { return key }
        f.locale = .current
        f.dateFormat = self == .week ? "EEE d" : self == .month ? "MMM d" : "MMM"
        return f.string(from: d)
    }
}

extension DB {
    func trends(since: String, range: TrendRange = .year) throws -> Trends {
        let prs = try query("""
            SELECT \(range.sql("merged_at")), author,
                   (julianday(merged_at) - julianday(created_at)) * 24, additions
            FROM prs WHERE merged_at >= ? ORDER BY merged_at
            """, [since]).map { r in
            PRRow(bucket: r[0] as! String, person: r[1] as! String, hours: r[2] as? Double ?? 0, additions: r[3] as? Int ?? 0)
        }

        let completed = try query("""
            SELECT \(range.sql("completed_at")), assignee, count(*)
            FROM issues WHERE completed_at >= ? AND assignee IS NOT NULL GROUP BY 1, 2
            """, [since]).map {
            Count(bucket: $0[0] as! String, person: displayName($0[1] as! String), n: $0[2] as! Int)
        }
        return Trends(prs: prs, completed: completed)
    }

    func merged(since: Date, author: String) -> [Date] {
        ((try? query("SELECT merged_at FROM prs WHERE author = ? AND merged_at >= ? ORDER BY merged_at", [author, iso.string(from: since)])) ?? [])
            .compactMap { ($0[0] as? String).flatMap(iso.date(from:)) }
    }
}

func monthPace(_ merged: [Date], now: Date = Date(), calendar: Calendar = .current) -> (totals: [Int], days: Int) {
    guard let month = calendar.dateInterval(of: .month, for: now), let days = calendar.range(of: .day, in: .month, for: now)?.count else { return ([], 30) }
    let today = calendar.component(.day, from: now)
    let perDay = Dictionary(grouping: merged.filter { month.contains($0) }) { calendar.component(.day, from: $0) }.mapValues(\.count)
    var total = 0
    return ((1...today).map { day in
        total += perDay[day] ?? 0
        return total
    }, days)
}
