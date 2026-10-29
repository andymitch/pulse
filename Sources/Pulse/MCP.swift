import AppKit

let pulseChanged = Notification.Name("com.andymitch.pulse.changed")
let pulseRegenerate = Notification.Name("com.andymitch.pulse.regenerate")

func runMCP() {
    let dir = Settings.dir
    while let line = readLine() {
        let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        let response = request.map { mcpResponse($0, dir: dir) } ?? ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Expected one JSON-RPC request object per line"]]
        guard let response, let out = try? JSONSerialization.data(withJSONObject: response) else { continue }
        FileHandle.standardOutput.write(out + Data("\n".utf8))
    }
}

private let mcpTools: [[String: Any]] = [
    tool("list_meetings", "Recent recorded meetings, newest first, with id, title, start, summary, and a recorded line that holds the length and attendees. Optionally filter by text or by how many days back.", [
        "query": ["type": "string", "description": "Only meetings whose title, summary, decisions or points contain this text"],
        "days": ["type": "integer", "description": "Only meetings from the last N days"],
        "limit": ["type": "integer", "description": "Most meetings to return, default 20"],
    ]),
    tool("get_meeting", "One meeting's summary, decisions and important points. The transcript is only included when asked for, a page of lines at a time.", [
        "id": ["type": "string", "description": "The meeting id from list_meetings"],
        "transcript": ["type": "boolean", "description": "Include the transcript"],
        "offset": ["type": "integer", "description": "First transcript line to return, default 0"],
        "lines": ["type": "integer", "description": "Transcript lines to return, default 200, at most 500"],
    ], required: ["id"]),
    tool("today", "Today's briefing: the team focus (the current priorities) with its sources, and the task list with ids, refs, links and estimates. done, later and removed reflect what was marked in Pulse today; live ticket and PR status isn't fetched. stale is true when the briefing wasn't made today.", [:]),
    tool("stats", "PRs merged and tickets closed per person per period, plus PR stats (median hours to merge, median lines added, PRs over 500 lines), as shown on Trends.", [
        "range": ["type": "string", "enum": TrendRange.allCases.map(\.rawValue), "description": "Period, default 5 weeks"],
        "person": ["type": "string", "description": "Only this person, by name"],
    ]),
    tool("update_task", "Mark one of today's tasks done or not done, move it to later or back up, or remove it for the day or restore it. Uses the ids from today. Only the fields given change.", [
        "id": ["type": "string", "description": "The task id from today"],
        "done": ["type": "boolean"], "later": ["type": "boolean"], "removed": ["type": "boolean"],
    ], required: ["id"], hints: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true]),
    tool("update_meeting", "Change a meeting's title, summary, decisions or important points. Only the fields given change; the transcript is kept.", [
        "id": ["type": "string", "description": "The meeting id from list_meetings"],
        "title": ["type": "string"], "summary": ["type": "string"],
        "decisions": ["type": "array", "items": ["type": "string"]], "points": ["type": "array", "items": ["type": "string"]],
    ], required: ["id"], hints: ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": true]),
    tool("delete_meeting", "Move a meeting's notes and transcript to the Trash.", [
        "id": ["type": "string", "description": "The meeting id from list_meetings"],
    ], required: ["id"], hints: ["readOnlyHint": false, "destructiveHint": true]),
    tool("regenerate_briefing", "Ask the running Pulse app to rebuild today's briefing. It runs in the background and takes a few minutes; check briefedAt in today afterwards.", [:],
         hints: ["readOnlyHint": false, "destructiveHint": false]),
]

private func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = [], hints: [String: Bool] = ["readOnlyHint": true]) -> [String: Any] {
    ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required],
     "annotations": hints.merging(["openWorldHint": false]) { a, _ in a }]
}

private func meetingFile(_ args: [String: Any], in archive: URL) throws -> (id: String, file: URL, markdown: String) {
    guard let id = args["id"] as? String, !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw SyncError(description: "Unknown meeting id") }
    let file = archive.appendingPathComponent(id + ".md")
    guard let markdown = try? String(contentsOf: file, encoding: .utf8) else { throw SyncError(description: "No meeting \(id)") }
    return (id, file, markdown)
}

private func briefing(_ dir: URL) throws -> Synthesis {
    guard let data = try? Data(contentsOf: dir.appendingPathComponent("synthesis.json")), let s = try? JSONDecoder().decode(Synthesis.self, from: data) else {
        throw SyncError(description: "No briefing yet")
    }
    return s
}

private func changed(_ dir: URL) {
    guard dir == Settings.dir else { return }
    DistributedNotificationCenter.default().postNotificationName(pulseChanged, object: nil, userInfo: nil, deliverImmediately: true)
}

func mcpResponse(_ request: [String: Any], dir: URL) -> [String: Any]? {
    guard let id = request["id"] else { return nil }
    let params = request["params"] as? [String: Any] ?? [:]
    var result: [String: Any]
    switch request["method"] as? String {
    case "initialize":
        let asked = params["protocolVersion"] as? String ?? ""
        result = ["protocolVersion": ["2025-06-18", "2025-03-26", "2024-11-05"].contains(asked) ? asked : "2025-06-18", "capabilities": ["tools": [:]],
                  "serverInfo": ["name": "pulse", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"]]
    case "ping":
        result = [:]
    case "tools/list":
        result = ["tools": mcpTools]
    case "tools/call":
        let args = params["arguments"] as? [String: Any] ?? [:]
        guard mcpTools.contains(where: { $0["name"] as? String == params["name"] as? String }) else {
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Unknown tool \(params["name"] ?? "")"]]
        }
        do {
            let value = try callTool(params["name"] as? String ?? "", args, dir: dir)
            let json = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
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
            .prefix(min(max(args["limit"] as? Int ?? 20, 0), 100))
            .map { ["id": $0.file.deletingPathExtension().lastPathComponent, "title": $0.title, "start": iso.string(from: $0.start), "recorded": $0.recorded, "summary": $0.summary] }
    case "get_meeting":
        let (id, file, markdown) = try meetingFile(args, in: archive)
        let m = parseMeeting(markdown, file: file, start: Date(timeIntervalSince1970: TimeInterval(id) ?? 0))
        var out: [String: Any] = ["id": id, "title": m.title, "start": iso.string(from: m.start), "recorded": m.recorded,
                                  "summary": m.summary, "decisions": m.decisions, "points": m.points]
        if args["transcript"] as? Bool == true {
            let lines = markdown.components(separatedBy: "\n## Transcript\n").dropFirst().joined()
                .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            let offset = max(0, args["offset"] as? Int ?? 0), count = min(max(1, args["lines"] as? Int ?? 200), 500)
            out["transcript"] = Array(lines.dropFirst(offset).prefix(count))
            out["transcriptLines"] = lines.count
        }
        return out
    case "today":
        let s = try briefing(dir)
        let file = dir.appendingPathComponent("synthesis.json")
        let briefed = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let db = try? DB(path: dir.appendingPathComponent("pulse.db").path, readOnly: true)
        let day = Date().formatted(localDay)
        let ids = { (key: String) in Set(db?.ids(key + "-" + day) ?? []) }
        let done = ids("done"), later = ids("later"), removed = ids("removed")
        let focus: [[String: Any]] = s.focus.map { f in
            let sources: [[String: Any]] = f.sources.compactMap { id in s.sources.first { $0.id == id } }.map { ["title": $0.title, "url": $0.url, "kind": $0.kind] }
            return ["headline": f.headline, "summary": f.summary, "sources": sources]
        }
        let today: [[String: Any]] = s.today.map { t in
            ([
                "id": t.id, "title": t.title, "why": t.why, "done": done.contains(t.id), "later": later.contains(t.id), "removed": removed.contains(t.id),
                "ref": t.ref, "url": t.url, "source": t.source, "minutes": t.minutes,
            ] as [String: Any?]).compactMapValues { $0 }
        }
        return (["focus": focus, "today": today, "briefedAt": briefed.map(iso.string(from:)),
                 "stale": !(briefed.map(Calendar.current.isDateInToday) ?? false)] as [String: Any?]).compactMapValues { $0 }
    case "stats":
        let range = (args["range"] as? String).flatMap(TrendRange.init) ?? .month
        let person = args["person"] as? String
        let db = try DB(path: dir.appendingPathComponent("pulse.db").path, readOnly: true)
        let buckets = range.buckets()
        let t = try db.trends(since: buckets[0], range: range, org: Settings.load().githubOrg)
        let matches = { (name: String) in person.map { name.caseInsensitiveCompare($0) == .orderedSame } ?? true }
        let prs = t.prs.filter { matches($0.person) }
        let closed = t.completed.filter { matches($0.person) }
        let stats = prStats(prs)
        return buckets.map { b in
            let merged = Dictionary(grouping: prs.filter { $0.bucket == b }, by: \.person).mapValues(\.count)
            let tickets = Dictionary(closed.filter { $0.bucket == b }.map { ($0.person, $0.n) }, uniquingKeysWith: +)
            let s = stats[b] ?? PrStats()
            return ["period": range.label(b), "start": b, "prsMerged": merged, "ticketsClosed": tickets,
                    "medianHoursToMerge": s.medianHours, "medianLinesAdded": s.medianAdditions, "prsOver500Lines": s.over500] as [String: Any]
        }
    case "update_task":
        let s = try briefing(dir)
        let briefed = (try? dir.appendingPathComponent("synthesis.json").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard briefed.map(Calendar.current.isDateInToday) == true else { throw SyncError(description: "The briefing isn't from today, so its tasks aren't on the list.") }
        guard let id = args["id"] as? String, let task = s.today.first(where: { $0.id == id }) else {
            throw SyncError(description: "Unknown task id. Use the ids from today.")
        }
        let db = try DB(path: dir.appendingPathComponent("pulse.db").path)
        let day = Date().formatted(localDay)
        var out: [String: Any] = ["id": id, "title": task.title]
        try db.transaction {
            for key in ["done", "later", "removed"] {
                var ids = Set(db.ids(key + "-" + day))
                if let on = args[key] as? Bool {
                    if on { ids.insert(id) } else { ids.remove(id) }
                    try db.set(Array(ids), key + "-" + day)
                }
                out[key] = ids.contains(id)
            }
        }
        changed(dir)
        return out
    case "update_meeting":
        let (id, file, markdown) = try meetingFile(args, in: archive)
        let flat = { (s: String) in s.split(whereSeparator: \.isNewline).joined(separator: " ") }
        guard let edited = editMeeting(markdown, title: (args["title"] as? String).map(flat), summary: args["summary"] as? String,
                                       decisions: (args["decisions"] as? [String])?.map(flat), points: (args["points"] as? [String])?.map(flat)) else {
            throw SyncError(description: "Meeting \(id) isn't in the format Pulse writes, so it wasn't changed.")
        }
        try edited.write(to: file, atomically: true, encoding: .utf8)
        changed(dir)
        let m = parseMeeting(edited, file: file, start: Date(timeIntervalSince1970: TimeInterval(id) ?? 0))
        return ["id": id, "title": m.title, "summary": m.summary, "decisions": m.decisions, "points": m.points]
    case "delete_meeting":
        let (id, file, _) = try meetingFile(args, in: archive)
        try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        changed(dir)
        return ["id": id, "deleted": true]
    case "regenerate_briefing":
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.andymitch.pulse").contains(where: { $0.processIdentifier != getpid() && $0.activationPolicy == .accessory }) else {
            throw SyncError(description: "Pulse isn't running. Open it to regenerate the briefing.")
        }
        DistributedNotificationCenter.default().postNotificationName(pulseRegenerate, object: nil, userInfo: nil, deliverImmediately: true)
        return ["asked": true]
    default:
        throw SyncError(description: "Unknown tool \(name)")
    }
}
