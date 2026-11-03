import Foundation

let factKinds = ["decision", "status", "blocker", "owner", "commitment", "question", "preference"]
let subjectKinds = ["project", "ticket", "person", "topic"]

struct FactChanges: Decodable {
    struct Subject: Decodable { let kind, name: String; let aliases: [String]? }
    struct Source: Decodable { let id: Int; let kind, url, title: String; let author, date, excerpt: String? }
    struct Add: Decodable { let subject: Subject; let kind, text, observed: String; let sources: [Int]; let supersedes: [Int]? }
    struct Confirm: Decodable { let id: Int; let sources: [Int] }
    let sources: [Source]?
    let add: [Add]?
    let confirm: [Confirm]?
}

struct FactCounts: Equatable { var added = 0, superseded = 0, confirmed = 0 }

private func day(_ s: String?, upTo today: String) -> String? {
    guard let d = s.map({ String($0.prefix(10)) }), (try? Date(d, strategy: localDay)) != nil else { return nil }
    return min(d, today)
}

func applyFacts(_ changes: FactChanges, to db: DB, now: Date = Date()) throws -> FactCounts {
    let today = now.formatted(localDay)
    var counts = FactCounts()
    try db.transaction {
        var sources: [Int: Int] = [:]
        for s in changes.sources ?? [] {
            guard let scheme = URL(string: s.url)?.scheme, ["http", "https", "file", "message"].contains(scheme), !s.title.isEmpty else { continue }
            let row = try db.query("""
                INSERT INTO sources (kind, url, title, author, date, excerpt) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (project, url) DO UPDATE SET title = excluded.title, excerpt = coalesce(excluded.excerpt, excerpt) RETURNING id
                """, [s.kind, s.url, s.title, s.author, day(s.date, upTo: today), s.excerpt])
            sources[s.id] = row.first?[0] as? Int
        }
        func cite(_ fact: Int, _ ids: [Int]) throws {
            for id in ids.compactMap({ sources[$0] }) { try db.query("INSERT OR IGNORE INTO fact_sources VALUES (?, ?)", [fact, id]) }
        }
        func current(_ id: Int) throws -> String? {
            try db.query("SELECT observed_at FROM facts WHERE id = ? AND superseded_by IS NULL", [id]).first?[0] as? String
        }
        for a in changes.add ?? [] {
            let text = a.text.trimmingCharacters(in: .whitespacesAndNewlines), name = a.subject.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard factKinds.contains(a.kind), subjectKinds.contains(a.subject.kind), !text.isEmpty, text.count <= 600, !name.isEmpty,
                  let observed = day(a.observed, upTo: today), a.sources.contains(where: { sources[$0] != nil }) else { continue }
            let subject = try subjectID(kind: a.subject.kind, names: [name] + (a.subject.aliases ?? []), in: db)
            if let same = try db.query("SELECT id FROM facts WHERE subject_id = ? AND text = ? AND superseded_by IS NULL", [subject, text]).first?[0] as? Int {
                try cite(same, a.sources)
                try db.query("UPDATE facts SET last_seen = max(last_seen, ?) WHERE id = ?", [observed, same])
                counts.confirmed += 1
                continue
            }
            let fact = try db.query("""
                INSERT INTO facts (subject_id, kind, text, observed_at, last_seen, recorded_at) VALUES (?, ?, ?, ?, ?, ?) RETURNING id
                """, [subject, a.kind, text, observed, observed, iso.string(from: now)])[0][0] as! Int
            try cite(fact, a.sources)
            counts.added += 1
            for old in a.supersedes ?? [] {
                guard let oldObserved = try current(old) else { continue }
                if oldObserved <= observed {
                    try db.query("UPDATE facts SET superseded_by = ? WHERE id = ?", [fact, old])
                    counts.superseded += 1
                } else {
                    try db.query("UPDATE facts SET superseded_by = ? WHERE id = ?", [old, fact])
                }
            }
        }
        for c in changes.confirm ?? [] {
            guard try current(c.id) != nil, c.sources.contains(where: { sources[$0] != nil }) else { continue }
            try cite(c.id, c.sources)
            try db.query("UPDATE facts SET status = 'confirmed', last_seen = max(last_seen, ?) WHERE id = ?", [today, c.id])
            counts.confirmed += 1
        }
    }
    return counts
}

private func subjectID(kind: String, names: [String], in db: DB) throws -> Int {
    let names = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    for (i, n) in names.enumerated() {
        let found = try db.query("""
            SELECT id, name, aliases FROM subjects WHERE kind = ? AND (name = ? COLLATE NOCASE OR (? AND EXISTS (SELECT 1 FROM json_each(aliases) WHERE value = ? COLLATE NOCASE)))
            ORDER BY name = ? COLLATE NOCASE DESC LIMIT 1
            """, [kind, n, i == 0 ? 1 : 0, n, n]).first
        guard let id = found?[0] as? Int, let name = found?[1] as? String else { continue }
        let known = (try? JSONDecoder().decode([String].self, from: Data((found?[2] as? String ?? "[]").utf8))) ?? []
        let all = (known + names).filter { $0.caseInsensitiveCompare(name) != .orderedSame }
        let aliases = all.enumerated().filter { i, a in !all.prefix(i).contains { $0.caseInsensitiveCompare(a) == .orderedSame } }.map(\.element)
        if aliases != known { try db.query("UPDATE subjects SET aliases = ? WHERE id = ?", [String(decoding: try JSONEncoder().encode(aliases), as: UTF8.self), id]) }
        return id
    }
    let aliases = String(decoding: try JSONEncoder().encode(Array(names.dropFirst())), as: UTF8.self)
    return try db.query("INSERT INTO subjects (kind, name, aliases) VALUES (?, ?, ?) RETURNING id", [kind, names[0], aliases])[0][0] as! Int
}

func currentFacts(_ db: DB) throws -> [[String: Any]] {
    try db.query("""
        SELECT f.id, s.kind, s.name, f.kind, f.text, f.observed_at, f.last_seen, f.status FROM facts f JOIN subjects s ON s.id = f.subject_id
        WHERE f.superseded_by IS NULL ORDER BY s.kind, s.name, f.observed_at DESC
        """).map { r in
        ["id": r[0]!, "subject": "\(r[1]!): \(r[2]!)", "kind": r[3]!, "text": r[4]!, "observed": r[5]!, "lastSeen": r[6]!, "status": r[7]!]
    }
}
