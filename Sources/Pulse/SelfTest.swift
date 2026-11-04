import AVFoundation
import FluidAudio
import AppKit
import Foundation

func selfTest() throws {
    let db = try DB(path: ":memory:")
    for (n, author, created, merged, adds) in [
        (1, "jane-acme", "2026-09-01T00:00:00Z", "2026-09-01T10:00:00Z", 100),
        (2, "acme-omar", "2026-09-02T00:00:00Z", "2026-09-02T20:00:00Z", 600),
        (3, "jane-acme", "2026-09-30T00:00:00Z", "2026-10-01T04:00:00Z", 50),
        (4, "jane-acme", "2025-01-01T00:00:00Z", "2025-01-02T00:00:00Z", 50),
        (5, "someone", "2026-09-03T00:00:00Z", "2026-09-03T01:00:00Z", 10),
    ] {
        try db.query("INSERT INTO prs VALUES ('r', ?, ?, ?, ?, ?)", [n, author, created, merged, adds])
    }
    try db.query("INSERT INTO users VALUES ('Jane Doe', 'jane@x.com'), ('Omar Reyes', 'omar@x.com'), ('Sam Lee', 'slee@x.com')")
    try db.query("INSERT INTO issues VALUES ('i1', 'i1', '', '', 'kai@x.com', NULL, '2026-09-05T00:00:00Z', '2026-10-02T00:00:00Z')")
    try db.query("INSERT INTO issues VALUES ('i2', 'i2', '', '', NULL, 'Omar Reyes', '2026-09-06T00:00:00Z', NULL)")

    let t = try db.trends(since: "2026-01-01", org: "acmecorp")
    func check(_ ok: Bool, _ what: String, line: Int = #line) {
        if !ok { FileHandle.standardError.write("FAIL line \(line): \(what)\n".data(using: .utf8)!); exit(1) }
    }
    check(t.prs.map(\.person) == ["Jane Doe", "Omar Reyes", "someone", "Jane Doe"], "github logins map to Linear names")
    let stats = prStats(t.prs.filter { $0.person != "someone" })
    check(stats["2026-09"]?.merged == 2 && stats["2026-10"]?.merged == 1, "merged per month")
    check(abs(stats["2026-09"]!.medianHours - 15) < 1e-6, "median hours")
    check(stats["2026-09"]?.medianAdditions == 350, "median additions")
    check(stats["2026-09"]?.over500 == 1, "over 500")
    check(t.completed.isEmpty, "completed skips missing assignee")
    check(prReasons(ci: "SUCCESS", mergeState: "UNKNOWN", decision: nil, unanswered: 0).reasons.isEmpty, "quiet PR is skipped")
    check(prReasons(ci: "SUCCESS", mergeState: "CLEAN", decision: "APPROVED", unanswered: 0).reasons == ["Approved, ready to merge"], "approved")
    check(prReasons(ci: "PENDING", mergeState: "CLEAN", decision: "APPROVED", unanswered: 0).reasons.isEmpty, "approved but CI pending")
    let bad = prReasons(ci: "FAILURE", mergeState: "BEHIND", decision: "APPROVED", unanswered: 2)
    check(bad.failing && bad.reasons == ["CI failing", "2 unanswered threads", "Behind main"], "failing and behind")
    let u = URL(string: "https://x")!
    let merged = mergeTicketsAndPRs([
        ActionItem(id: "KLE-1", kind: .ticket, title: "One", reason: "KLE-1 · In Review", url: u, ticket: "KLE-1", started: true, branch: "kle-1-one", priority: 3, since: Date()),
        ActionItem(id: "KLE-2", kind: .ticket, title: "Two", reason: "KLE-2 · Todo", url: u, ticket: "KLE-2", branch: "kle-2-two", priority: 2, since: Date()),
        ActionItem(id: "pr1", kind: .failing, title: "Fix one", reason: "CI failing", url: u, started: true, branch: "kle-1-one", pr: u, since: Date()),
        ActionItem(id: "pr9", kind: .pr, title: "Loose PR", reason: "Behind main", url: u, started: true, branch: "other", pr: u, since: Date()),
        ActionItem(id: "rev", kind: .review, title: "Their PR", reason: "Review", url: u, pr: u, since: Date()),
    ])
    check(merged.map(\.id) == ["KLE-1", "rev", "pr9", "KLE-2"], "ticket absorbs its PR and takes its urgency")
    check(merged[0].kind == .failing && merged[0].pr == u && merged[0].reason.hasSuffix("CI failing"), "merged ticket carries PR state")
    check(!merged[3].started && merged[3].pr == nil, "todo ticket stays startable")
    let weeks = try db.trends(since: "2026-09-01", range: .month, org: "acmecorp")
    check(Set(weeks.prs.map(\.bucket)) == ["2026-08-31", "2026-09-28"], "weeks start on Monday")
    check(TrendRange.month.buckets(now: iso.date(from: "2026-10-21T12:00:00Z")!) == ["2026-09-21", "2026-09-28", "2026-10-05", "2026-10-12", "2026-10-19"], "last 5 weeks")
    check(TrendRange.week.buckets(now: iso.date(from: "2026-10-21T12:00:00Z")!).last == "2026-10-21", "last 7 days end today")
    check(autoAffix(org: "acmecorp", logins: ["jane-acme", "priyaacme", "acme-omar", "someone"]) == "acme", "affix from org name")
    check(autoAffix(org: "acme", logins: ["jane", "bob"]) == "", "no affix when logins don't share it")
    try db.query("INSERT INTO prs VALUES ('r', 6, 'zz-handle', '2026-09-04T00:00:00Z', '2026-09-04T01:00:00Z', 1)")
    try db.query("INSERT INTO github_users VALUES ('zz-handle', 'Sam Lee')")
    check(try db.trends(since: "2026-09-04", org: "acmecorp").prs.first?.person == "Sam Lee", "GitHub profile name wins")
    check(Version("v2")! > Version("1.4.0")!, "major beats minor")
    check(Version("2.0.0-beta.3")! < Version("v2")!, "stable beats its beta")
    check(Version("v2-beta.2")! < Version("v2-beta.10")!, "beta numbers compare as numbers")
    check(Version("v2-beta.1")! > Version("v1.3")!, "a beta of the next major beats the current stable")
    check(!(Version("1.0.0")! < Version("v1")!), "1.0.0 equals v1")
    let migrated = Settings.load(Data(#"{"meetings": ["superwhisper", "otter"], "superwhisperFolder": "~/x", "githubOrg": "acme"}"#.utf8))
    check(migrated.recordMeetings && migrated.githubOrg == "acme", "Superwhisper setting becomes recording, other settings kept")
    check(!Settings.load(Data(#"{"meetings": ["otter"]}"#.utf8)).recordMeetings && Settings.load(Data("{}".utf8)).recordMeetings, "recording stays off if it was off, and is on by default")
    var off = Settings()
    off.hotkey = .off
    check(Settings.load(try JSONEncoder().encode(off)).hotkey == .off && Settings.load(Data("{}".utf8)).hotkey == .standard, "a turned-off shortcut stays off")
    let key = { (flags: NSEvent.ModifierFlags) in NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40).flatMap(Hotkey.init) }
    check(key([.command, .option])?.label == "⌥⌘K" && key([.command, .option])?.modifiers == 2304 && key([.shift]) == nil, "a shortcut needs a modifier and is labelled in order")
    let w = { (word: String, t: Double) in WordTiming(word: word, startTime: t, endTime: t + 0.3) }
    let lines = transcriptText(mine: [w("Ship", 0), w("it.", 0.4), w("Sounds", 5.2), w("Agreed.", 70)],
                               theirs: [w("Sounds", 5), w("good.", 5.4), w("Next", 61), w("week.", 61.5)],
                               turns: [Turn(speaker: "S7", start: 4.8, end: 6), Turn(speaker: "S2", start: 60.5, end: 62)],
                               me: "Jane", attendees: ["Omar", "Priya"])
    check(lines == "[0:00] Jane: Ship it.\n[0:05] Speaker 1: Sounds good.\n[1:01] Speaker 2: Next week.\n[1:10] Jane: Agreed.", "transcript merges tracks, drops echo, numbers speakers")
    check(transcriptText(mine: [], theirs: [w("Hi", 1)], turns: [], me: "Jane", attendees: ["Omar"]) == "[0:01] Omar: Hi", "one other attendee is named")
    let standup = Meeting(title: "Standup", start: Date(timeIntervalSince1970: 0), me: "Jane", attendees: ["Omar"], minutes: 15)
    let notes = MeetingNotes(title: "Standup", summary: "Talked launch.\nAll good.", decisions: ["Ship Friday"], points: ["Omar: update docs", "Risk: QA time"], speakers: nil)
    let file = URL(fileURLWithPath: "/m/0.md")
    let parsed = parseMeeting(meetingMarkdown(standup, notes: notes, transcript: "[0:01] Jane: # Not a title\n- not a point"), file: file, start: standup.start)
    check(parsed.title == "Standup" && parsed.recorded.hasPrefix("Recorded ") && parsed.summary == notes.summary, "saved meeting keeps title and summary")
    check(parsed.decisions == notes.decisions && parsed.points == notes.points, "saved meeting keeps decisions and points, not the transcript")
    let long = MeetingNotes(title: "Standup", summary: "", decisions: (1...7).map { "**D\($0)** why" }, points: [], speakers: nil)
    check(parseMeeting(meetingMarkdown(standup, notes: long, transcript: ""), file: file, start: standup.start).decisions == Array(long.decisions.prefix(5)), "saved meeting keeps at most 5 decisions")
    let bare = parseMeeting(meetingMarkdown(standup, notes: nil, transcript: "[0:01] Jane: Hi"), file: file, start: standup.start)
    check(bare.title == "Standup" && bare.summary.isEmpty && bare.decisions.isEmpty, "meeting saved without a summary")
    let rate = 16000.0
    let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let tone = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 1600)!
    tone.frameLength = 1600
    let audio = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-selftest-\(UUID()).caf")
    defer { try? FileManager.default.removeItem(at: audio) }
    let track = try AVAudioFile(forWriting: audio, settings: mono.settings)
    try append(tone, to: track, since: Date())
    try append(tone, to: track, since: Date(timeIntervalSinceNow: -3))
    check((48000...48100).contains(track.length), "a gap in the audio is filled with silence so tracks stay aligned")
    let high = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!, frameCapacity: 4800)!
    high.frameLength = 4800
    let converter = AVAudioConverter(from: high.format, to: mono)!
    let converted = (0..<10).compactMap { _ in convert(high, with: converter)?.frameLength }.reduce(0, +)
    check(abs(Int(converted) - 16000) < 300, "mic audio is converted when the input format changes")
    check(spokenWords("[0:26] Andrew Mitchell: Uh") == 1 && spokenWords("[61:02] Jane: Note: ship it\n[61:05] Speaker 1: Sure") == 4, "spoken words skip timestamps and speakers")
    let reply = { (title: String) in Synthesis.Todo(ref: nil, title: title, why: "", url: "message://%3Cm1%3E", source: "mail", minutes: 5) }
    check(reply("Reply to Dana").id == reply("Reply to Dana about the date").id, "a reworded briefing item keeps its done state")
    let thread = slackThread(URL(string: "https://acme.slack.com/archives/C08QBJ75EUB/p1761234567123456")!)
    let inThread = slackThread(URL(string: "https://acme.slack.com/archives/C08QBJ75EUB/p1761234999000100?thread_ts=1761234567.123456&cid=C08QBJ75EUB")!)
    check(thread?.channel == "C08QBJ75EUB" && thread?.thread == "1761234567.123456" && inThread?.thread == "1761234567.123456" && slackThread(URL(string: "https://x.com/archives/C1/p1761234567123456")!) == nil
          && slackThread(URL(string: "https://acme.slack.com/archives/C1/p1")!) == nil, "Slack links give the channel and thread to reply in, and others are refused")
    let old = try JSONDecoder().decode(Synthesis.Todo.self, from: Data(#"{"ref": null, "title": "Reply", "why": "", "url": null, "source": "slack", "minutes": 5}"#.utf8))
    check(old.reply == nil, "a briefing from before suggested replies still loads")
    let archive = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-meetings-\(UUID())")
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: archive) }
    let now = Int(Date().timeIntervalSince1970)
    for t in [now - 86400, now - 3600, now - 30 * 86400] { try Data().write(to: archive.appendingPathComponent("\(t).md")) }
    check(meetingTranscripts(in: archive).map { URL(fileURLWithPath: $0).lastPathComponent } == ["\(now - 3600).md", "\(now - 86400).md"], "briefing meetings are newest first and skip old ones")
    let mem = try DB(path: ":memory:")
    let changes = { (json: String) in try applyFacts(try JSONDecoder().decode(FactChanges.self, from: Data(json.utf8)), to: mem, now: iso.date(from: "2026-11-03T12:00:00Z")!) }
    let slack = #""sources": [{"id": 1, "kind": "slack", "url": "https://x.slack.com/archives/C1/p1", "title": "Maya in #eng"}, {"id": 2, "kind": "doc", "url": "javascript:alert(1)", "title": "Bad"}]"#
    let fact = { (subject: String, text: String, observed: String, extra: String) in
        #"{"subject": {"kind": "ticket", "name": "\#(subject)", "aliases": ["Invite teammates"]}, "kind": "status", "text": "\#(text)", "observed": "\#(observed)", "sources": [1]\#(extra)}"#
    }
    check(try changes("{\(slack), \"add\": [\(fact("KLE-1", "Invites are in review", "2026-11-01", ""))]}") == FactCounts(added: 1), "a new fact is added with its subject and source")
    check(try changes("{\(slack), \"add\": [\(fact("invite teammates", "Invites are in review", "2026-11-02", ""))]}") == FactCounts(confirmed: 1), "the same fact under a subject alias confirms it instead of adding it again")
    check(try changes("{\(slack), \"add\": [\(fact("KLE-1", "Invites merged", "2026-11-03", ", \"supersedes\": [1]"))]}") == FactCounts(added: 1, superseded: 1), "a newer fact supersedes the old one")
    check(try changes("{\(slack), \"add\": [\(fact("KLE-1", "Invites are blocked", "2026-10-20", ", \"supersedes\": [2]"))]}") == FactCounts(added: 1), "an older fact can't supersede a newer one")
    check(try currentFacts(mem).map { $0["text"] as? String } == ["Invites merged"], "only the newest fact is current")
    check(try changes("{\(slack), \"add\": [\(fact("KLE-2", "Uncited", "2026-11-03", "").replacingOccurrences(of: "[1]", with: "[2]")), \(fact("KLE-2", "Soon", "2027-01-01", "").replacingOccurrences(of: "status", with: "rumor"))], \"confirm\": [{\"id\": 1, \"sources\": [1]}]}") == FactCounts(),
          "facts without a real source or a known kind, and confirmations of superseded facts, are skipped")
    let future = try changes("{\(slack), \"add\": [\(fact("KLE-3", "Due Friday", "2027-01-01", ""))]}")
    let dated = try mem.query("SELECT observed_at FROM facts WHERE text = 'Due Friday'")[0][0] as? String
    check(future == FactCounts(added: 1) && dated == "2026-11-03", "a fact dated in the future is dated today, and a shared alias doesn't merge two tickets")
    let counts = try mem.query("SELECT (SELECT count(*) FROM subjects), (SELECT count(*) FROM sources)")[0]
    check(counts[0] as? Int == 2 && counts[1] as? Int == 1, "subjects and sources are reused")
    let texts = { (facts: [[String: Any]]) in facts.map { $0["text"] as? String ?? "" } }
    let state = FileManager.default.temporaryDirectory.appendingPathComponent("slack-state-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: state) }
    try Data(#"{"workspaces": {"T02ABC": {"domain": "acme", "name": "Acme"}}}"#.utf8).write(to: state)
    let deep = slackDeepLink(URL(string: "https://acme.slack.com/archives/C08QBJ75EUB/p1793817031868429?thread_ts=1793810000.000100&cid=C08QBJ75EUB")!, state: state)
    check(deep?.absoluteString == "slack://channel?team=T02ABC&id=C08QBJ75EUB&message=1793817031.868429&thread_ts=1793810000.000100"
          && slackDeepLink(URL(string: "https://other.slack.com/archives/C1/p1793817031868429")!, state: state) == nil,
          "a Slack message link opens at that message in the Slack app, and other workspaces fall back to the browser")
    let slackLink = URL(string: "https://acme.slack.com/archives/C1/p1")!, linearLink = URL(string: "https://linear.app/acme/review/fix-it")!
    check(sourceKind(slackLink, given: "session") == "slack" && sourceKind(linearLink, given: "doc") == "linear" && sourceKind(URL(fileURLWithPath: "/x/Pulse/sessions/pi-1.md"), given: "doc") == "session"
          && sourceKind(URL(string: "message://%3Ca%3E")!, given: "doc") == "mail", "a source's kind comes from its link, whatever the agent called it")
    check(sourceTitle("https://acme.slack.com/archives/C1/p1", url: slackLink) == "Slack message" && sourceTitle("", url: linearLink) == "Linear review"
          && sourceTitle("Standup", url: slackLink) == "Standup" && sourceTitle("https://x.slack.com/a", url: URL(fileURLWithPath: "/x/Pulse/sessions/pi-1.md")) == "pi session",
          "a source titled with a bare link gets a readable name")
    let real = try DB(path: ":memory:")
    try real.query("INSERT INTO users VALUES ('Jane Doe', 'jane@x.com')")
    try real.set(["Requests v1", "MCP v2"], "linear_projects")
    let linked = try realSubject(kind: "project", names: ["requests V1"], in: real), made = try realSubject(kind: "project", names: ["Pulse"], in: real)
    let stranger = try realSubject(kind: "person", names: ["Maya"], in: real), teammate = try realSubject(kind: "person", names: ["jane doe"], in: real)
    let titled = try realSubject(kind: "topic", names: ["Invite teammates", "KLE-9"], in: real)
    check(linked.kind == "project" && linked.names[0] == "Requests v1", "a project subject takes the Linear project's own name")
    check(made.kind == "topic" && stranger.kind == "topic" && teammate.kind == "person" && teammate.names[0] == "Jane Doe", "only Linear projects and teammates are projects and people; anything else is a topic")
    check(titled.kind == "ticket" && titled.names == ["KLE-9", "Invite teammates"], "a subject with a ticket ID is that ticket, named by the ID")
    try real.query("INSERT INTO subjects (kind, name, aliases) VALUES ('project', 'Pulse', '[]'), ('topic', 'mcp v2', '[]'), ('ticket', 'Ship invites', '[\"KLE-4\"]'), ('ticket', 'KLE-5', '[\"Requests v1\"]')")
    try fixSubjects(real)
    check(try real.query("SELECT kind || ':' || name FROM subjects ORDER BY id").compactMap { $0[0] as? String } == ["topic:Pulse", "project:MCP v2", "ticket:KLE-4", "project:Requests v1"],
          "existing subjects are fixed up to real projects, tickets and topics, and a project name wins over a ticket ID")
    let invites = try searchFacts(mem, query: "invite")
    check(texts(invites) == ["Due Friday", "Invites merged"] && (invites[1]["replaces"] as? [[String: Any]])?.count == 2, "search finds current facts by word stem or subject alias, with what they replaced")
    let replaced = (try searchFacts(mem, query: "invites are"), try searchFacts(mem, query: "invites are", superseded: true))
    check(replaced.0.isEmpty && texts(replaced.1) == ["Invites are in review", "Invites are blocked"], "replaced facts are only returned when asked for, newest first")
    check(texts(try searchFacts(mem, query: "KLE-3")) == ["Due Friday"], "search matches a subject name")
    check(texts(try searchFacts(mem, since: "2026-11-03")) == ["Due Friday", "Invites merged"], "search since a date lists what changed")
    check(texts(try searchFacts(mem, query: "\"merged* (")) == ["Invites merged"], "search treats quotes, stars and brackets in the query as plain words")
    let ticket = try subjectFacts(mem, name: "invite teammates") as? [String: Any]
    check(ticket?["name"] as? String == "KLE-1" && (ticket?["current"] as? [Any])?.count == 1 && (ticket?["history"] as? [Any])?.count == 2, "a subject by alias shows current facts and history")
    check((try subjectFacts(mem, name: nil) as? [[String: Any]])?.map { $0["name"] as? String } == ["KLE-1", "KLE-3"], "subjects list most recently active first, then by name")
    let noted = { (subject: String, text: String, replaces: Int) in
        try applyFacts(FactChanges(sources: nil, add: [FactChanges.Add(subject: FactChanges.Subject(kind: "ticket", name: subject, aliases: nil), kind: "status", text: text,
                                                                      observed: "2026-11-03", sources: [], supersedes: [replaces])], confirm: nil),
                       to: mem, now: iso.date(from: "2026-11-03T12:00:00Z")!, origin: "agent")
    }
    let agentAdded = try noted("KLE-1", "Invites shipped to everyone", 2)
    let stillCurrent = texts(try searchFacts(mem, query: "invites")).contains("Invites merged")
    check(agentAdded == FactCounts(added: 1) && stillCurrent, "an agent's fact needs no source and doesn't replace a confirmed one yet")
    let before = try changedFacts(mem, since: "2026-11-03T00:00:00Z"), afterwards = try changedFacts(mem, since: "2026-11-03T13:00:00Z")
    check(before.map { $0["text"] as? String } == ["Due Friday", "Invites merged"] && afterwards.isEmpty && (before[1]["replaces"] as? [Any])?.count == 2,
          "since you last looked lists confirmed facts learned after that time, newest first, with what they replaced, and skips agents' unconfirmed ones")
    let pending = try unconfirmedFacts(mem)
    check(pending.map(\.text) == ["Invites shipped to everyone"] && pending[0].replaces == ["Invites merged"], "unconfirmed facts are listed with what they'd replace")
    try confirmFact(mem, id: pending[0].id, text: "Invites shipped to all workspaces")
    let afterConfirm = (try searchFacts(mem, query: "workspaces"), try searchFacts(mem, query: "invites"), try unconfirmedFacts(mem))
    check(texts(afterConfirm.0) == ["Invites shipped to all workspaces"] && !texts(afterConfirm.1).contains("Invites merged") && afterConfirm.2.isEmpty,
          "confirming with an edit saves the new text, finds it in search, and replaces the old fact")
    try rejectFact(mem, id: pending[0].id)
    let afterReject = (try searchFacts(mem, query: "invites"), try searchFacts(mem, query: "workspaces", superseded: true))
    check(texts(afterReject.0).contains("Invites merged") && afterReject.1.isEmpty, "rejecting a fact hides it and makes what it replaced current again")
    _ = try noted("KLE-3", "Due next Friday", 4)
    let checked = try changes("{\(slack), \"confirm\": [{\"id\": \(try unconfirmedFacts(mem)[0].id), \"sources\": [1]}]}")
    let due = try searchFacts(mem, query: "KLE-3")
    check(checked == FactCounts(confirmed: 1) && texts(due) == ["Due next Friday"], "a briefing run confirming an agent's fact applies what it replaces")
    let piLog = [
        #"{"type":"session","cwd":"/code/app","timestamp":"2026-11-03T10:00:00Z"}"#,
        #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Ship the invite flow"}]}}"#,
        #"{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Done, PR #9 is open."},{"type":"toolCall","name":"bash"}]}}"#,
        #"{"type":"message","message":{"role":"toolResult","content":[{"type":"text","text":"tool output"}]}}"#,
        #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Keep the flag on for now"}]}}"#,
    ].joined(separator: "\n")
    let claudeLog = [
        #"{"type":"user","cwd":"/code/api","message":{"role":"user","content":"Fix the retry bug"}}"#,
        #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"subagent prompt"}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"output"}]}}"#,
        #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Fixed in #12."},{"type":"tool_use","name":"Edit"}]}}"#,
        #"{"type":"user","message":{"role":"user","content":"Thanks, merge it"}}"#,
    ].joined(separator: "\n")
    let pi = sessionTurns(Data(piLog.utf8)), claude = sessionTurns(Data(claudeLog.utf8))
    check(pi.cwd == "/code/app" && pi.turns == [SessionTurn(you: true, text: "Ship the invite flow"), SessionTurn(you: false, text: "Done, PR #9 is open."), SessionTurn(you: true, text: "Keep the flag on for now")],
          "a pi session keeps what was said, without thinking, tool calls or tool output")
    check(claude.cwd == "/code/api" && claude.turns.map(\.text) == ["Fix the retry bug", "Fixed in #12.", "Thanks, merge it"], "a Claude Code session skips subagents, tool results and slash commands")
    let at = iso.date(from: "2026-11-03T10:00:00Z")!
    check(sessionDigest(tool: "pi", cwd: nil, start: at, end: at, turns: [SessionTurn(you: true, text: "One shot")]) == nil, "a session with one message from me isn't worth a digest")
    let chatty = (1...60).map { SessionTurn(you: $0 % 2 == 1, text: "turn \($0) " + String(repeating: "x", count: 1000)) }
    let digest = sessionDigest(tool: "pi", cwd: "/code/app", start: at, end: at, turns: chatty) ?? ""
    check(digest.hasPrefix("# turn 1 x") && digest.contains("turn 60 ") && !digest.contains("turn 2 ") && digest.contains("earlier messages left out") && digest.count < 42_000,
          "a long session keeps its first message and the latest ones under the cap")
    let roots = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-sessions-\(UUID())")
    defer { try? FileManager.default.removeItem(at: roots) }
    let project = roots.appendingPathComponent("pi/--code-app--"), digests = roots.appendingPathComponent("out")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let log = { (name: String, body: String, ago: Double) throws in
        let url = project.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ago)], ofItemAtPath: url.path)
    }
    try log("old.jsonl", piLog, 3 * 3600)
    try log("new.jsonl", piLog.replacingOccurrences(of: "invite flow", with: "billing page"), 3600)
    try log("live.jsonl", piLog, 60)
    try log("oneshot.jsonl", #"{"type":"message","message":{"role":"user","content":"Just once"}}"#, 3600)
    let lookalike = roots.appendingPathComponent("pi/--code-application--")
    try FileManager.default.createDirectory(at: lookalike, withIntermediateDirectories: true)
    try piLog.replacingOccurrences(of: "/code/app", with: "/code/application").write(to: lookalike.appendingPathComponent("other.jsonl"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: lookalike.appendingPathComponent("other.jsonl").path)
    try FileManager.default.createDirectory(at: digests, withIntermediateDirectories: true)
    try "# Résumé\n\npi session in /Users/me, 2026-11-01T00:00:00Z to 2026-11-01T01:00:00Z.\n".write(to: digests.appendingPathComponent("pi-personal.md"), atomically: true, encoding: .utf8)
    let found = digestSessions(into: digests, folders: ["/code/app"], roots: [("pi", roots.appendingPathComponent("pi"))])
    check(found.map { URL(fileURLWithPath: $0).lastPathComponent } == ["pi-new.md", "pi-old.md"], "finished sessions in the repo get digests, newest first; live and one-message sessions don't")
    check(!FileManager.default.fileExists(atPath: digests.appendingPathComponent("pi-other.md").path) && !FileManager.default.fileExists(atPath: digests.appendingPathComponent("pi-personal.md").path),
          "sessions outside the repo, even in a folder with a similar name, aren't digested, and old digests from outside it are deleted")
    check(digestSessions(into: digests, folders: [], roots: [("pi", roots.appendingPathComponent("pi"))]).isEmpty, "without a repo in Settings, no sessions are used")
    try log("old.jsonl", piLog.replacingOccurrences(of: "invite flow", with: "invite page"), 1800)
    let again = digestSessions(into: digests, folders: ["/code/app/"], roots: [("pi", roots.appendingPathComponent("pi"))])
    let refreshed = try String(contentsOfFile: again[0], encoding: .utf8)
    check(again.first.map { URL(fileURLWithPath: $0).lastPathComponent } == "pi-old.md" && refreshed.contains("invite page"),
          "a session picked up again gets a fresh digest")
    let prompt = { (since: String?) in synthesisPrompt(output: "o", today: "Tuesday", me: "Jane", transcripts: [], mail: nil, candidates: [], facts: "f.json", factsOutput: "n.json", since: since) }
    let later = prompt("2026-11-03T22:00:00Z"), first = prompt(nil)
    check(later.contains("documents created since 2026-11-03T22:00:00Z") && later.contains("gather only what's new") && !later.contains("in the last 14 days")
          && first.contains("documents created in the last 14 days") && later.range(of: "n.json")!.lowerBound < later.range(of: "to o with")!.lowerBound,
          "after a run the briefing reads only what's new, a first run reads 14 days, and memory is updated before the briefing is written")
    let d = "2026-11-03"
    check(withoutOwnDate("On 2026-11-03 Drew Osmond opened PR #2047.", d) == "Drew Osmond opened PR #2047."
          && withoutOwnDate("As of 2026-11-03 document unification met 9 of 10 criteria.", d) == "Document unification met 9 of 10 criteria."
          && withoutOwnDate("Change orders are plain requests (decided 2026-11-03).", d) == "Change orders are plain requests."
          && withoutOwnDate("Jason said to skip auto-close, on 2026-11-03.", d) == "Jason said to skip auto-close.",
          "a fact's own date is left out of its text, since it's shown beside it")
    let short = { (day: String) in (try? Date(day, strategy: localDay))?.formatted(Calendar.current.component(.year, from: try! Date(day, strategy: localDay)) == Calendar.current.component(.year, from: Date()) ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year()) ?? day }
    check(withoutOwnDate("On 2026-11-02 Abe reported a gap.", d) == "On \(short("2026-11-02")) Abe reported a gap." && withoutOwnDate("Open as of 2026-11-03: who owns it.", d) == "Open as of \(short(d)): who owns it."
          && withoutOwnDate("Requests had not reached prod as of 2026-11-03, so launch moved to Monday 2026-11-09.", d) == "Requests had not reached prod, so launch moved to Monday \(short("2026-11-09")).",
          "other dates stay but read as short dates, and the fact's own date is dropped mid-sentence too")
    let wed = try Date("2026-11-04", strategy: localDay).addingTimeInterval(12 * 3600)
    let oct20 = try Date("2026-10-20", strategy: localDay).formatted(.dateTime.month(.abbreviated).day())
    check(friendlyDay("2026-11-04", now: wed) == "Today" && friendlyDay("2026-11-03", now: wed) == "Yesterday" && friendlyDay("2026-11-01", now: wed) == "Sunday"
          && friendlyDay("2026-10-20", now: wed) == oct20,
          "dates read as today, yesterday, a weekday this week, or a short date")
    try MainActor.assumeIsolated {
        let store = Store(db: try DB(path: ":memory:"), dir: FileManager.default.temporaryDirectory.appendingPathComponent("pulse-selftest-\(UUID())"))
        store.today = (1...8).map { ActionItem(id: "T\($0)", kind: .ticket, title: "T\($0)", reason: "", url: URL(string: "https://x")!, since: Date()) }
        store.remove("T2")
        store.toggleLater("T1")
        check(store.checklist.map(\.id) == ["T3", "T4", "T5", "T6", "T7", "T1"], "without a plan, a removed item is backfilled and a later one moves to the bottom")
        check(!store.moreItems.map(\.id).contains("T2"), "a removed item isn't in More either")
        store.restoreRemoved()
        check(store.checklist.map(\.id).first == "T2", "restoring brings removed items back")
        store.toggleDone("T3")
        check(store.doneThisWeek.isEmpty, "nothing is logged before a successful fetch")
        store.fetchedOK = true
        store.recordDone()
        check(store.doneThisWeek.map(\.id) == ["T3"] && store.earlierThisWeek.isEmpty, "checking an item off logs it for the week, but today's stay in the checklist")
        check(Store(db: store.db, dir: store.dir).doneThisWeek.map(\.id) == ["T3"], "the week's done list survives a restart")
        store.toggleDone("T3")
        check(store.doneThisWeek.isEmpty, "unchecking it today takes it back out")
        store.doneThisWeek = [DoneItem(id: "old", title: "Old", url: URL(string: "https://x")!, source: "", day: "2000-01-03"),
                              DoneItem(id: "T4", title: "T4", url: URL(string: "https://x")!, source: "", day: "2000-01-03")]
        store.recordDone()
        check(store.earlierThisWeek.map(\.id) == ["old"], "earlier days show unless the item is back on today's list")
        let todo = { (ref: String) in Synthesis.Todo(ref: ref, title: ref, why: "", url: nil, source: "linear", minutes: 30) }
        let state = { (type: String) in WorkflowState(id: type, name: type, type: type, color: "#000000", position: 0) }
        store.doneThisWeek = []
        store.synthesis = Synthesis(focus: [], today: ["K-1", "K-2", "K-3", "https://github.com/o/r/pull/1"].map(todo), sources: [])
        store.synthesizedAt = Date()
        store.closedTickets = nil
        check(store.checklist.filter { $0.id.hasPrefix("K-") }.allSatisfy { !$0.done }, "briefing tickets stay unchecked when Linear couldn't be read")
        store.closedTickets = ["K-2": state("completed"), "K-3": state("canceled")]
        let rows = store.checklist.filter { !$0.id.hasPrefix("T") }
        check(rows.map(\.id) == ["K-2", "K-3", "https://github.com/o/r/pull/1"] && rows.allSatisfy(\.done), "a briefing ticket that left the list for the backlog drops off, closed ones and merged PRs are done")
        store.recordDone()
        check(store.doneThisWeek.map(\.id) == ["K-2", "https://github.com/o/r/pull/1"], "only completed tickets and merged PRs go in the week's done log")
    }
    let mcpDir = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-mcp-\(UUID())")
    defer { try? FileManager.default.removeItem(at: mcpDir) }
    try FileManager.default.createDirectory(at: mcpDir.appendingPathComponent("meetings"), withIntermediateDirectories: true)
    try meetingMarkdown(standup, notes: notes, transcript: "[0:01] Jane: One\n[0:02] Omar: Two\n[0:03] Jane: Three")
        .write(to: mcpDir.appendingPathComponent("meetings/0.md"), atomically: true, encoding: .utf8)
    try JSONEncoder().encode(Synthesis(focus: [], today: [reply("Reply to Dana"), Synthesis.Todo(ref: "T-1", title: "Ship it", why: "", url: nil, source: "linear", minutes: 30)], sources: []))
        .write(to: mcpDir.appendingPathComponent("synthesis.json"))
    let mcpDB = try DB(path: mcpDir.appendingPathComponent("pulse.db").path)
    try mcpDB.setMeta("done-" + Date().formatted(localDay), "[\"\(reply("Reply to Dana").id)\"]")
    let call = { (name: String, args: [String: Any]) -> Any? in
        let result = mcpResponse(["id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]], dir: mcpDir)?["result"] as? [String: Any]
        let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }
    check(((mcpResponse(["id": 1, "method": "tools/list"], dir: mcpDir)?["result"] as? [String: Any])?["tools"] as? [Any])?.count == 12, "MCP lists its twelve tools")
    check((mcpResponse(["id": 1, "method": "nope"], dir: mcpDir)?["error"] as? [String: Any])?["code"] as? Int == -32601 && mcpResponse(["method": "notifications/initialized"], dir: mcpDir) == nil, "MCP rejects unknown methods and doesn't answer notifications")
    check((call("list_meetings", ["query": "launch"]) as? [[String: Any]])?.first?["id"] as? String == "0", "MCP finds a meeting by text")
    let page = call("get_meeting", ["id": "0", "transcript": true, "offset": 1, "lines": 1]) as? [String: Any]
    check(page?["transcript"] as? [String] == ["[0:02] Omar: Two"] && page?["transcriptLines"] as? Int == 3 && page?["decisions"] as? [String] == notes.decisions, "MCP pages a meeting transcript")
    check(call("get_meeting", ["id": "../x"]) == nil, "MCP rejects a meeting id that isn't a timestamp")
    check(((call("today", [:]) as? [String: Any])?["today"] as? [[String: Any]])?.map { $0["done"] as? Bool } == [true, false], "MCP today marks done items")
    check((call("stats", ["range": "7 days"]) as? [Any])?.count == 7, "MCP stats has one entry per period")
    _ = try applyFacts(try JSONDecoder().decode(FactChanges.self, from: Data("{\(slack), \"add\": [\(fact("KLE-1", "Invites merged", "2026-11-03", ""))]}".utf8)), to: mcpDB)
    check(((call("search", ["query": "merged"]) as? [[String: Any]])?.first?["sources"] as? [[String: Any]])?.first?["url"] as? String == "https://x.slack.com/archives/C1/p1", "MCP search returns facts with their sources")
    check((call("subject", ["name": "KLE-1"]) as? [String: Any])?["name"] as? String == "KLE-1" && call("subject", ["name": "nope"]) == nil, "MCP subject finds one by name and errors on an unknown one")
    let remembered = call("remember", ["subject": "KLE-1", "subjectKind": "ticket", "fact": "Invites need a feature flag", "kind": "decision", "sourceUrl": "https://github.com/o/r/pull/9", "sourceTitle": "Flag invites"]) as? [String: Any]
    check(remembered?["status"] as? String == "unconfirmed" && call("remember", ["subject": "KLE-1", "subjectKind": "ticket", "fact": "x", "kind": "rumor"]) == nil, "MCP remember saves an unconfirmed fact and refuses an unknown kind")
    check((call("forget", ["id": remembered?["id"] as? Int ?? 0]) as? [String: Any])?["forgotten"] as? Bool == true && (call("search", ["query": "flag"]) as? [Any])?.isEmpty == true, "MCP forget hides a fact")
    _ = call("update_task", ["id": "T-1", "done": true, "removed": true])
    let tasks = (call("today", [:]) as? [String: Any])?["today"] as? [[String: Any]]
    check(tasks?.last?["id"] as? String == "T-1" && tasks?.last?["done"] as? Bool == true && tasks?.last?["removed"] as? Bool == true, "MCP marks a task done and removed")
    _ = call("update_task", ["id": "T-1", "removed": false])
    check(((call("today", [:]) as? [String: Any])?["today"] as? [[String: Any]])?.last?["removed"] as? Bool == false, "MCP restores a removed task and leaves done alone")
    check(call("update_task", ["id": "nope", "done": true]) == nil, "MCP refuses a task id that isn't in today")
    let edited = call("update_meeting", ["id": "0", "summary": "Shipped.", "decisions": ["Line one\nline two"]]) as? [String: Any]
    let after = call("get_meeting", ["id": "0", "transcript": true]) as? [String: Any]
    check(edited?["summary"] as? String == "Shipped." && after?["decisions"] as? [String] == ["Line one line two"] && after?["title"] as? String == "Standup"
          && after?["points"] as? [String] == notes.points && after?["transcriptLines"] as? Int == 3, "MCP edits a meeting's notes and keeps the rest and the transcript")
    _ = call("update_meeting", ["id": "0", "summary": "Fine.\n## Transcript\nfake"])
    check((call("get_meeting", ["id": "0", "transcript": true]) as? [String: Any])?["transcriptLines"] as? Int == 3, "a heading in an edited summary can't cut the transcript")
    check(editMeeting("# Old\n\nRecorded.\n\n## Notes\n\nx\n\n## Transcript\n\nhi", title: "New", summary: nil, decisions: nil, points: nil) == nil
          && editMeeting("# Old\n\nRecorded.", title: "New", summary: nil, decisions: nil, points: nil) == nil, "a meeting Pulse didn't write isn't edited")
    try Data(#"{"agentAccess": false}"#.utf8).write(to: mcpDir.appendingPathComponent("settings.json"))
    check(call("list_meetings", [:]) == nil, "MCP refuses tool calls while agent access is off")
    print("self-test ok")
}
