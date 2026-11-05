import Foundation

let factKinds = ["decision", "status", "blocker", "owner", "commitment", "question", "preference"]
let subjectKinds = ["project", "ticket", "person", "topic"]

struct FactChanges: Decodable {
    struct Subject: Decodable { let kind, name: String; let aliases: [String]? }
    struct Source: Decodable { let id: Int; let kind, url, title: String; let author, date, excerpt: String? }
    struct Add: Decodable { let subject: Subject; let kind, text, observed: String; let sources: [Int]; let supersedes: [Int]?; var doubt: String? = nil }
    struct Confirm: Decodable { let id: Int; let sources: [Int] }
    struct Doubt: Decodable { let id: Int; let reason: String }
    let sources: [Source]?
    let add: [Add]?
    let confirm: [Confirm]?
    var doubt: [Doubt]? = nil
}

struct FactCounts: Equatable { var added = 0, superseded = 0, confirmed = 0 }

func sourceKind(_ url: URL, given: String) -> String {
    let host = url.host ?? ""
    if host == "slack.com" || host.hasSuffix(".slack.com") { return "slack" }
    if host == "linear.app" { return "linear" }
    if host == "github.com" { return "github" }
    if url.scheme == "message" { return "mail" }
    if url.isFileURL { return url.path.contains("/sessions/") ? "session" : url.path.contains("/meetings/") ? "meeting" : given }
    return given
}

func sourceTitle(_ title: String, url: URL) -> String {
    guard title.hasPrefix("http") || title.isEmpty else { return title }
    switch sourceKind(url, given: "") {
    case "slack": return "Slack message"
    case "linear": return "Linear " + (url.pathComponents.dropFirst(2).first ?? "page")
    case "github": return "GitHub " + url.pathComponents.dropFirst(1).prefix(2).joined(separator: "/")
    case "session": return url.lastPathComponent.hasPrefix("claude-") ? "Claude Code session" : "pi session"
    case "meeting": return "Meeting notes"
    default: return url.host ?? "Link"
    }
}

private func day(_ s: String?, upTo today: String) -> String? {
    guard let d = s.map({ String($0.prefix(10)) }), (try? Date(d, strategy: localDay)) != nil else { return nil }
    return min(d, today)
}

private let live = "superseded_by IS NULL AND status != 'rejected'"

private func current(_ db: DB, _ id: Int) throws -> String? {
    try db.query("SELECT observed_at FROM facts WHERE id = ? AND \(live)", [id]).first?[0] as? String
}

private func supersede(_ db: DB, new: Int, observed: String, olds: [Int]) throws -> Int {
    var n = 0
    for old in olds where old != new {
        guard let oldObserved = try current(db, old), try current(db, new) != nil else { continue }
        if oldObserved <= observed {
            try db.query("UPDATE facts SET superseded_by = ? WHERE id = ?", [new, old])
            n += 1
        } else {
            try db.query("UPDATE facts SET superseded_by = ? WHERE id = ?", [old, new])
        }
    }
    return n
}

private func confirm(_ db: DB, _ id: Int, seen: String) throws {
    guard let observed = try current(db, id) else { return }
    try db.query("UPDATE facts SET status = 'confirmed', doubt = NULL, last_seen = max(last_seen, ?) WHERE id = ?", [seen, id])
    let olds = try db.query("SELECT replaces_id FROM pending_replaces WHERE fact_id = ?", [id]).compactMap { $0[0] as? Int }
    _ = try supersede(db, new: id, observed: observed, olds: olds)
    try db.query("DELETE FROM pending_replaces WHERE fact_id = ?", [id])
}

func applyFacts(_ changes: FactChanges, to db: DB, now: Date = Date(), origin: String = "briefing") throws -> FactCounts {
    let agent = origin == "agent"
    let today = now.formatted(localDay)
    var counts = FactCounts()
    try db.transaction {
        var sources: [Int: Int] = [:]
        for s in changes.sources ?? [] {
            guard let scheme = URL(string: s.url)?.scheme, ["http", "https", "file", "message"].contains(scheme), !s.title.isEmpty else { continue }
            let row = try db.query("""
                INSERT INTO sources (kind, url, title, author, date, excerpt) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (project, url) DO UPDATE SET title = excluded.title, excerpt = coalesce(excluded.excerpt, excerpt) RETURNING id
                """, [URL(string: s.url).map { sourceKind($0, given: s.kind) } ?? s.kind, s.url, s.title, s.author, day(s.date, upTo: today), s.excerpt])
            sources[s.id] = row.first?[0] as? Int
        }
        func cite(_ fact: Int, _ ids: [Int]) throws {
            for id in ids.compactMap({ sources[$0] }) { try db.query("INSERT OR IGNORE INTO fact_sources VALUES (?, ?)", [fact, id]) }
        }
        for a in changes.add ?? [] {
            let text = a.text.trimmingCharacters(in: .whitespacesAndNewlines), name = a.subject.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard factKinds.contains(a.kind), subjectKinds.contains(a.subject.kind), !text.isEmpty, text.count <= 600, !name.isEmpty,
                  let observed = day(a.observed, upTo: today), agent || a.sources.contains(where: { sources[$0] != nil }) else { continue }
            let subject = try subjectID(kind: a.subject.kind, names: [name] + (a.subject.aliases ?? []), in: db)
            if let same = try db.query("SELECT id FROM facts WHERE subject_id = ? AND text = ? AND \(live)", [subject, text]).first?[0] as? Int {
                try cite(same, a.sources)
                try db.query("UPDATE facts SET last_seen = max(last_seen, ?) WHERE id = ?", [observed, same])
                counts.confirmed += 1
                continue
            }
            let doubt = agent ? nil : a.doubt.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            let fact = try db.query("""
                INSERT INTO facts (subject_id, kind, text, observed_at, last_seen, recorded_at, status, origin, doubt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id
                """, [subject, a.kind, text, observed, observed, iso.string(from: now), agent || doubt != nil ? "unconfirmed" : "confirmed", origin, doubt])[0][0] as! Int
            try cite(fact, a.sources)
            counts.added += 1
            if agent || doubt != nil {
                for old in a.supersedes ?? [] {
                    if try current(db, old) != nil { try db.query("INSERT OR IGNORE INTO pending_replaces VALUES (?, ?)", [fact, old]) }
                }
            } else {
                counts.superseded += try supersede(db, new: fact, observed: observed, olds: a.supersedes ?? [])
            }
        }
        for c in changes.confirm ?? [] {
            guard try current(db, c.id) != nil, c.sources.contains(where: { sources[$0] != nil }) else { continue }
            try cite(c.id, c.sources)
            try confirm(db, c.id, seen: today)
            counts.confirmed += 1
        }
        for d in changes.doubt ?? [] where !agent {
            let reason = d.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty, try current(db, d.id) != nil else { continue }
            try db.query("UPDATE facts SET doubt = ? WHERE id = ?", [reason, d.id])
        }
    }
    return counts
}

func isTicketID(_ s: String) -> Bool { s.range(of: "^[A-Z][A-Z0-9]*-[0-9]+$", options: .regularExpression) != nil }

private func known(_ db: DB) throws -> (projects: [String], people: [String]) {
    (db.ids("linear_projects"), try db.query("SELECT name FROM users").compactMap { $0[0] as? String })
}

func realSubject(kind: String, names: [String], in db: DB) throws -> (kind: String, names: [String]) {
    let (projects, people) = try known(db)
    let match = { (list: [String]) in names.lazy.compactMap { n in list.first { $0.caseInsensitiveCompare(n) == .orderedSame } }.first }
    if let p = match(projects) { return ("project", [p] + names.filter { $0.caseInsensitiveCompare(p) != .orderedSame }) }
    if let id = names.first(where: isTicketID) { return ("ticket", [id] + names.filter { $0 != id }) }
    if let p = match(people) { return ("person", [p] + names.filter { $0.caseInsensitiveCompare(p) != .orderedSame }) }
    return ("topic", names)
}

func fixSubjects(_ db: DB) throws {
    for r in try db.query("SELECT id, kind, name, aliases FROM subjects") {
        let aliases = (try? JSONDecoder().decode([String].self, from: Data((r[3] as? String ?? "[]").utf8))) ?? []
        let real = try realSubject(kind: r[1] as! String, names: [r[2] as! String] + aliases, in: db)
        guard real.kind != r[1] as? String || real.names[0] != r[2] as? String else { continue }
        try db.query("UPDATE subjects SET kind = ?, name = ?, aliases = ? WHERE id = ?",
                     [real.kind, real.names[0], String(decoding: try JSONEncoder().encode(Array(real.names.dropFirst())), as: UTF8.self), r[0]])
    }
}

private func subjectID(kind asked: String, names given: [String], in db: DB) throws -> Int {
    let (kind, names) = try realSubject(kind: asked, names: given.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }, in: db)
    for (i, n) in names.enumerated() {
        let found = try db.query("""
            SELECT id, name, aliases FROM subjects WHERE name = ? COLLATE NOCASE OR (? AND EXISTS (SELECT 1 FROM json_each(aliases) WHERE value = ? COLLATE NOCASE))
            ORDER BY name = ? COLLATE NOCASE DESC LIMIT 1
            """, [n, i == 0 ? 1 : 0, n, n]).first
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
    try db.query("\(factColumns) WHERE f.\(live) ORDER BY s.kind, s.name, f.observed_at DESC").map { try factJSON(db, $0) }
}

private func factJSON(_ db: DB, _ r: [Any?]) throws -> [String: Any] {
    let id = r[0] as! Int
    let sources = try db.query("""
        SELECT s.kind, s.url, s.title, s.author, s.date, s.excerpt FROM sources s JOIN fact_sources fs ON fs.source_id = s.id WHERE fs.fact_id = ? ORDER BY s.date DESC
        """, [id]).map { s in
        (["kind": s[0], "url": s[1], "title": s[2], "author": s[3], "date": s[4], "excerpt": s[5]] as [String: Any?]).compactMapValues { $0 }
    }
    let replaces = try db.query("SELECT id, text, observed_at FROM facts WHERE superseded_by = ? AND status != 'rejected' ORDER BY observed_at DESC", [id])
        .map { ["id": $0[0]!, "text": $0[1]!, "observed": $0[2]!] }
    return ([
        "id": id, "subject": ([
            "kind": r[1]!, "name": r[2]!,
            "title": r[1] as? String == "ticket" ? (try? JSONDecoder().decode([String].self, from: Data((r[9] as? String ?? "[]").utf8)))?.first : nil,
        ] as [String: Any?]).compactMapValues { $0 }, "kind": r[3], "text": r[4], "observed": r[5], "lastSeen": r[6], "status": r[7],
        "supersededBy": r[8], "recorded": r[10], "doubt": r[11], "sources": sources, "replaces": replaces.isEmpty ? nil : replaces,
    ] as [String: Any?]).compactMapValues { $0 }
}

private let factColumns = "SELECT f.id, s.kind, s.name, f.kind, f.text, f.observed_at, f.last_seen, f.status, f.superseded_by, s.aliases, f.recorded_at, f.doubt FROM facts f JOIN subjects s ON s.id = f.subject_id"

func searchFacts(_ db: DB, query: String = "", since: String? = nil, kind: String? = nil, superseded: Bool = false, limit: Int = 30) throws -> [[String: Any]] {
    var conditions = ["f.status != 'rejected'"], args: [Any?] = []
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let words = q.split { !$0.isLetter && !$0.isNumber }
    if !words.isEmpty {
        conditions.append("(f.id IN (SELECT rowid FROM facts_fts WHERE facts_fts MATCH ?) OR s.name LIKE ? OR s.aliases LIKE ?)")
        args += [words.map { "\"\($0)\"*" }.joined(separator: " "), "%\(q)%", "%\(q)%"]
    }
    if let since { conditions.append("f.observed_at >= ?"); args.append(String(since.prefix(10))) }
    if let kind { conditions.append("f.kind = ?"); args.append(kind) }
    if !superseded { conditions.append("f.superseded_by IS NULL") }
    return try db.query("\(factColumns) WHERE \(conditions.joined(separator: " AND ")) ORDER BY f.observed_at DESC, f.id DESC LIMIT ?",
                        args + [min(max(limit, 1), 100)]).map { try factJSON(db, $0) }
}

func subjectFacts(_ db: DB, name: String?) throws -> Any {
    guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
        return try db.query("""
            SELECT s.kind, s.name, count(f.id), max(f.observed_at), s.aliases FROM subjects s JOIN facts f ON f.subject_id = s.id AND f.\(live)
            GROUP BY s.id ORDER BY max(f.observed_at) DESC, s.name
            """).map { ["kind": $0[0]!, "name": $0[1]!, "facts": $0[2]!, "latest": $0[3]!,
                        "aliases": (try? JSONDecoder().decode([String].self, from: Data(($0[4] as? String ?? "[]").utf8))) ?? []] }
    }
    guard let s = try db.query("""
        SELECT id, kind, name, aliases FROM subjects
        WHERE name = ? COLLATE NOCASE OR EXISTS (SELECT 1 FROM json_each(aliases) WHERE value = ? COLLATE NOCASE)
        ORDER BY name = ? COLLATE NOCASE DESC LIMIT 1
        """, [name, name, name]).first else {
        let close = try db.query("SELECT name FROM subjects WHERE name LIKE ? OR aliases LIKE ? ORDER BY name LIMIT 10", ["%\(name)%", "%\(name)%"]).compactMap { $0[0] as? String }
        throw SyncError(description: "No subject named \(name)." + (close.isEmpty ? " Call subject with no name to list them." : " Close: \(close.joined(separator: ", "))."))
    }
    let facts = try db.query("\(factColumns) WHERE f.subject_id = ? AND f.status != 'rejected' ORDER BY f.observed_at DESC, f.id DESC", [s[0]]).map { try factJSON(db, $0) }
    return [
        "kind": s[1]!, "name": s[2]!, "aliases": (try? JSONDecoder().decode([String].self, from: Data((s[3] as? String ?? "[]").utf8))) ?? [],
        "current": facts.filter { $0["supersededBy"] == nil }, "history": facts.filter { $0["supersededBy"] != nil },
    ]
}

func confirmFact(_ db: DB, id: Int, text: String? = nil) throws {
    let text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let text, text.isEmpty || text.count > 600 { throw SyncError(description: "A fact is one sentence of up to 600 characters.") }
    try db.transaction {
        guard try current(db, id) != nil else { throw SyncError(description: "No current fact \(id)") }
        if let text { try db.query("UPDATE facts SET text = ? WHERE id = ?", [text, id]) }
        try confirm(db, id, seen: Date().formatted(localDay))
    }
}

func rejectFact(_ db: DB, id: Int) throws {
    try db.transaction {
        guard try current(db, id) != nil else { throw SyncError(description: "No current fact \(id)") }
        try db.query("UPDATE facts SET status = 'rejected' WHERE id = ?", [id])
        try db.query("UPDATE facts SET superseded_by = NULL WHERE superseded_by = ?", [id])
        try db.query("DELETE FROM pending_replaces WHERE fact_id = ?", [id])
    }
}

func doubtedFacts(_ db: DB) throws -> [[String: Any]] {
    try db.query("\(factColumns) WHERE f.doubt IS NOT NULL AND f.\(live) ORDER BY f.recorded_at DESC, f.id DESC").map { r in
        var fact = try factJSON(db, r)
        let pending = try db.query("SELECT o.id, o.text, o.observed_at FROM pending_replaces p JOIN facts o ON o.id = p.replaces_id WHERE p.fact_id = ? AND o.\(live)", [fact["id"]])
            .map { ["id": $0[0]!, "text": $0[1]!, "observed": $0[2]!] }
        if !pending.isEmpty { fact["replaces"] = pending }
        return fact
    }
}

func factsByID(_ db: DB, _ ids: [Int]) throws -> [[String: Any]] {
    try ids.compactMap { id in try db.query("\(factColumns) WHERE f.id = ?", [id]).first.map { try factJSON(db, $0) } }
}

private let stopwords: Set<String> = ["the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "is", "are", "was", "were", "be", "it", "its",
    "what", "whats", "who", "whom", "when", "where", "why", "how", "which", "does", "do", "did", "has", "have", "had", "there", "about", "any", "anything",
    "me", "my", "we", "our", "us", "this", "that", "these", "those", "can", "could", "should", "would", "will", "s", "left", "now", "tell", "know", "pulse"]

func factsFor(question: String, in db: DB, limit: Int = 8) throws -> [[String: Any]] {
    let lower = question.lowercased()
    var ids: [Int] = []
    let named = try db.query("SELECT s.id, s.name, s.aliases FROM subjects s").filter { r in
        let names = [r[1] as? String ?? ""] + ((try? JSONDecoder().decode([String].self, from: Data((r[2] as? String ?? "[]").utf8))) ?? [])
        return names.contains { $0.count >= 4 && lower.contains($0.lowercased()) }
    }.compactMap { $0[0] as? Int }
    for subject in named {
        ids += try db.query("SELECT id FROM facts WHERE subject_id = ? AND \(live) ORDER BY observed_at DESC LIMIT 4", [subject]).compactMap { $0[0] as? Int }
    }
    let words = question.split { !$0.isLetter && !$0.isNumber }.map { $0.lowercased() }.filter { !stopwords.contains($0) && $0.count > 1 }
    if !words.isEmpty {
        ids += try db.query("""
            SELECT f.id FROM facts_fts JOIN facts f ON f.id = facts_fts.rowid WHERE facts_fts MATCH ? AND f.\(live)
            ORDER BY bm25(facts_fts), f.observed_at DESC LIMIT ?
            """, [words.map { "\"\($0)\"*" }.joined(separator: " OR "), limit]).compactMap { $0[0] as? Int }
    }
    var seen = Set<Int>()
    let picked = ids.filter { seen.insert($0).inserted }.prefix(limit)
    return try picked.compactMap { id in try db.query("\(factColumns) WHERE f.id = ?", [id]).first.map { try factJSON(db, $0) } }
}
