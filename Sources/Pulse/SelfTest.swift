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
    try MainActor.assumeIsolated {
        let store = Store(db: try DB(path: ":memory:"), dir: FileManager.default.temporaryDirectory.appendingPathComponent("pulse-selftest-\(UUID())"))
        store.today = (1...8).map { ActionItem(id: "T\($0)", kind: .ticket, title: "T\($0)", reason: "", url: URL(string: "https://x")!, since: Date()) }
        store.remove("T2")
        store.toggleLater("T1")
        check(store.checklist.map(\.id) == ["T3", "T4", "T5", "T6", "T7", "T1"], "a removed item is replaced and a later one moves to the bottom")
        check(!store.moreItems.map(\.id).contains("T2"), "a removed item isn't in More either")
        store.restoreRemoved()
        check(store.checklist.map(\.id).first == "T2", "restoring brings removed items back")
    }
    print("self-test ok")
}
