import Foundation

func runMCP() {
    let dir = Settings.dir
    while let line = readLine() {
        guard let data = line.data(using: .utf8),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let response = mcpResponse(request, dir: dir),
              let out = try? JSONSerialization.data(withJSONObject: response) else { continue }
        FileHandle.standardOutput.write(out + Data("\n".utf8))
    }
}

private let mcpTools: [[String: Any]] = [
    tool("list_meetings", "Recent recorded meetings, newest first, with title, when, length, attendees and summary. Optionally filter by text or by how many days back.", [
        "query": ["type": "string", "description": "Only meetings whose title, summary, decisions or points contain this text"],
        "days": ["type": "integer", "description": "Only meetings from the last N days"],
        "limit": ["type": "integer", "description": "Most meetings to return, default 20"],
    ]),
    tool("get_meeting", "One meeting's summary, decisions and important points. The transcript is only included when asked for, a page of lines at a time.", [
        "id": ["type": "string", "description": "The meeting id from list_meetings"],
        "transcript": ["type": "boolean", "description": "Include the transcript"],
        "offset": ["type": "integer", "description": "First transcript line to return, default 0"],
        "lines": ["type": "integer", "description": "Transcript lines to return, default 200"],
    ], required: ["id"]),
    tool("today", "Today's briefing: the team focus with its sources, and the Today checklist with refs, links and estimates. done, later and removed reflect what was marked in Pulse today; live ticket and PR status isn't fetched.", [:]),
    tool("stats", "PRs merged and tickets closed per person per period, plus PR stats (median hours to merge, median lines added, PRs over 500 lines), as shown on Trends.", [
        "range": ["type": "string", "enum": TrendRange.allCases.map(\.rawValue), "description": "Period, default 5 weeks"],
        "person": ["type": "string", "description": "Only this person"],
    ]),
]

private func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
    ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required],
     "annotations": ["readOnlyHint": true]]
}

func mcpResponse(_ request: [String: Any], dir: URL) -> [String: Any]? {
    guard let id = request["id"] else { return nil }
    let params = request["params"] as? [String: Any] ?? [:]
    var result: [String: Any]
    switch request["method"] as? String {
    case "initialize":
        result = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18", "capabilities": ["tools": [:]],
                  "serverInfo": ["name": "pulse", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"]]
    case "ping":
        result = [:]
    case "tools/list":
        result = ["tools": mcpTools]
    case "tools/call":
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            let value = try callTool(params["name"] as? String ?? "", args, dir: dir)
            let json = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            result = ["content": [["type": "text", "text": String(decoding: json, as: UTF8.self)]]]
        } catch {
            result = ["content": [["type": "text", "text": "\(error)"]], "isError": true]
        }
    default:
        return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unknown method \(request["method"] ?? "")"]]
    }
    return ["jsonrpc": "2.0", "id": id, "result": result]
}

private func callTool(_ name: String, _ args: [String: Any], dir: URL) throws -> Any {
    let archive = dir.appendingPathComponent("meetings")
    switch name {
    case "list_meetings":
        let since = (args["days"] as? Int).map { Date().addingTimeInterval(-Double($0) * 86400) } ?? .distantPast
        let query = (args["query"] as? String ?? "").lowercased()
        return savedMeetings(in: archive, limit: .max)
            .filter { $0.start >= since }
            .filter { m in query.isEmpty || ([m.title, m.summary] + m.decisions + m.points).joined(separator: "\n").lowercased().contains(query) }
            .prefix(args["limit"] as? Int ?? 20)
            .map { ["id": $0.file.deletingPathExtension().lastPathComponent, "title": $0.title, "start": iso.string(from: $0.start), "recorded": $0.recorded, "summary": $0.summary] }
    case "get_meeting":
        guard let id = args["id"] as? String, id.allSatisfy(\.isNumber), let start = TimeInterval(id) else { throw SyncError(description: "Unknown meeting id") }
        let file = archive.appendingPathComponent(id + ".md")
        guard let markdown = try? String(contentsOf: file, encoding: .utf8) else { throw SyncError(description: "No meeting \(id)") }
        let m = parseMeeting(markdown, file: file, start: Date(timeIntervalSince1970: start))
        var out: [String: Any] = ["id": id, "title": m.title, "start": iso.string(from: m.start), "recorded": m.recorded,
                                  "summary": m.summary, "decisions": m.decisions, "points": m.points]
        if args["transcript"] as? Bool == true {
            let lines = markdown.components(separatedBy: "\n## Transcript\n").dropFirst().joined()
                .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            let offset = max(0, args["offset"] as? Int ?? 0), count = max(1, args["lines"] as? Int ?? 200)
            out["transcript"] = Array(lines.dropFirst(offset).prefix(count))
            out["transcriptLines"] = lines.count
        }
        return out
    case "today":
        let file = dir.appendingPathComponent("synthesis.json")
        guard let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Synthesis.self, from: data) else {
            throw SyncError(description: "No briefing yet")
        }
        let briefed = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let db = try DB(path: dir.appendingPathComponent("pulse.db").path, readOnly: true)
        let day = Date().formatted(.iso8601.year().month().day())
        let ids = { (key: String) in Set(db.meta(key + "-" + day).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []) }
        let done = ids("done"), later = ids("later"), removed = ids("removed")
        let focus: [[String: Any]] = s.focus.map { f in
            let sources: [[String: Any]] = f.sources.compactMap { id in s.sources.first { $0.id == id } }.map { ["title": $0.title, "url": $0.url, "kind": $0.kind] }
            return ["headline": f.headline, "summary": f.summary, "sources": sources]
        }
        let today: [[String: Any]] = s.today.filter { !removed.contains($0.id) }.map { t in
            var row: [String: Any] = ["title": t.title, "why": t.why, "done": done.contains(t.id), "later": later.contains(t.id)]
            row["ref"] = t.ref
            row["url"] = t.url
            row["source"] = t.source
            row["minutes"] = t.minutes
            return row
        }
        var out: [String: Any] = ["focus": focus, "today": today]
        out["briefedAt"] = briefed.map(iso.string(from:))
        return out
    case "stats":
        let range = (args["range"] as? String).flatMap(TrendRange.init) ?? .month
        let person = args["person"] as? String
        let db = try DB(path: dir.appendingPathComponent("pulse.db").path, readOnly: true)
        let buckets = range.buckets()
        let t = try db.trends(since: buckets[0], range: range, org: Settings.load().githubOrg)
        let prs = t.prs.filter { person == nil || $0.person == person }
        let closed = t.completed.filter { person == nil || $0.person == person }
        let stats = prStats(prs)
        return buckets.map { b in
            let merged = Dictionary(grouping: prs.filter { $0.bucket == b }, by: \.person).mapValues(\.count)
            let tickets = Dictionary(closed.filter { $0.bucket == b }.map { ($0.person, $0.n) }, uniquingKeysWith: +)
            let s = stats[b] ?? PrStats()
            return ["period": range.label(b), "start": b, "prsMerged": merged, "ticketsClosed": tickets,
                    "medianHoursToMerge": s.medianHours, "medianLinesAdded": s.medianAdditions, "prsOver500Lines": s.over500] as [String: Any]
        }
    default:
        throw SyncError(description: "Unknown tool \(name)")
    }
}
