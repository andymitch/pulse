import Foundation

struct Synthesis: Codable {
    struct Focus: Codable {
        let headline, summary: String
        let sources: [Int]
    }
    struct Todo: Codable {
        let ref: String?
        let title, why: String
        let url, source: String?
        let minutes: Int?

        var id: String { ref ?? "ai-" + (url ?? title) }
    }
    struct Source: Codable {
        let id: Int
        let title, url, kind: String
        let author, date, excerpt: String?
    }
    let focus: [Focus]
    let today: [Todo]
    let sources: [Source]
}

func meetingTranscripts(in archive: URL, days: Int = 14) -> [String] {
    let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
    return ((try? FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)) ?? [])
        .filter { (TimeInterval($0.deletingPathExtension().lastPathComponent) ?? 0) > cutoff.timeIntervalSince1970 }
        .map(\.path)
        .sorted()
}

func synthesisPrompt(output: String, today: String, me: String, transcripts: [String], mail: String?, candidates: [ActionItem]) -> String {
    let s = settings
    var who = ["Linear \"\(me)\""]
    if s.slack { who.append("the Slack user your Slack tools are logged in as") }
    var gather: [String] = []
    gather.append("Linear: the active cycles and what is in them, projects and initiatives with their latest status updates, and documents created in the last 14 days (meeting minutes).")
    if s.slack {
        let channels = s.slackChannels.map { "#\($0.name) (\($0.id))" }.joined(separator: ", ")
        gather.append("Slack, the last 14 days of " + (channels.isEmpty ? "the up to 12 busiest channels \(me) is a member of, skipping channels that are mostly bots or alerts." : "these channels: \(channels)."))
        gather.append("Slack messages that need \(me): mentions of them and DMs to them from the last 7 days, keeping only those not yet answered.")
    }
    if let mail { gather.append("Email from the last \(s.mailDays) days, as JSON with a url for each message: \(mail). Keep only email that needs \(me) to reply or act; ignore newsletters and notifications.") }
    var meetings: [String] = []
    if s.meetings.contains(.record) { meetings.append("meetings Pulse recorded, each a file with its summary, decisions, important points and the transcript: \(transcripts.isEmpty ? "none this period" : transcripts.joined(separator: ", "))") }
    if s.meetings.contains(.otter) { meetings.append("Otter summaries and otter.ai links posted in Slack or emailed") }
    if s.meetings.contains(.loom) { meetings.append("Loom recordings (loom.com links) shared in Slack or email, using their titles and any summary text") }
    if !meetings.isEmpty { gather.append("Meetings: " + meetings.joined(separator: "; ") + ".") }
    gather.append("\(me)'s open work right now, from GitHub and Linear. Each line starts with its ref:\n" + candidates.map { "   - ref \($0.id) | \($0.summary)" }.joined(separator: "\n"))
    let kinds = ["github", "linear"] + (s.slack ? ["slack"] : []) + (mail != nil ? ["mail"] : []) + ["meeting", "doc"]
    let kindList = kinds.map { "\"\($0)\"" }.joined(separator: " | ")

    return """
    You are writing the morning briefing for Pulse, \(me)'s dashboard. Today is \(today). \(me) is \(who.joined(separator: ", ")).

    This is read-only. Never post, react, comment, create, or change anything anywhere.

    Gather, using your Linear and Slack tools (MCP servers; in pi, call them through codemode):
    \(gather.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))

    Then write one JSON file to \(output) with exactly this shape and nothing else:
    {
      "focus": [{"headline": string, "summary": string, "sources": [int]}],
      "today": [{"ref": string | null, "title": string, "why": string, "url": string | null, "source": \(kindList) | null, "minutes": int}],
      "sources": [{"id": int, "title": string, "url": string, "kind": \(kindList), "author": string | null, "date": "YYYY-MM-DD" | null, "excerpt": string | null}]
    }

    Rules:
    - focus: cut through the noise. Usually exactly one entry: the single thing the team is pushing on right now. Add a second or third only if there are genuinely separate efforts in flight that matter as much; never more than 3. headline is one short line. summary is 3 to 5 plain sentences distilled from everything you read: what the goal is, where it stands, what is blocking it, and what \(me)'s part is. Leave out minor threads. Use inline Markdown to make it scannable: **bold** for the goal, the blocker and \(me)'s part, *italics* for people and docs, and `code` for ticket IDs and endpoints. No headings or lists. Each entry cites the 2 to 4 sources that best back it up.
    - today: \(me)'s checklist for today, at most 7 items that fit in about 5 hours of focused work, in the order to do them. Put first what unblocks other people (reviews, replies, merges), then work that is nearly done, then the most important work for the focus. For an item from the open work list, set ref to its ref exactly and keep its title. Other items are unanswered questions or requests, or meeting action items assigned to \(me) by name: set ref to null, title starts with a verb, and url points at the thread, message, email or doc. why is one short line. minutes is an honest estimate.
    - sources: every cited item, numbered from 1. url must be a link you actually saw; never invent one, and drop any claim you cannot link. For a meeting transcript file, url is "file://" followed by its path and author is null. title is what the item is (a ticket title, a doc name, an email subject, or "Maya in #engineering"). excerpt is the most telling one or two sentences, quoted or closely paraphrased. author and date are who wrote it and when, if known.
    - Write plainly. No hype, no filler.
    """
}

func runSynthesis(dir: URL, candidates: [ActionItem], me: String) async throws -> Synthesis {
    let out = dir.appendingPathComponent("synthesis.next.json")
    let prompt = dir.appendingPathComponent("synthesis-prompt.md")
    try? FileManager.default.removeItem(at: out)
    let day = Date().formatted(date: .complete, time: .omitted)
    var mail: String?
    var mailError: String?
    if settings.mail {
        let file = dir.appendingPathComponent("mail/inbox.json")
        do {
            try await Task.detached { try exportMail(days: settings.mailDays, to: file) }.value
            mail = file.path
        } catch {
            mailError = "Mail export failed: \(error)"
        }
    }
    let transcripts = settings.meetings.contains(.record) ? meetingTranscripts(in: dir.appendingPathComponent("meetings")) : []
    try synthesisPrompt(output: out.path, today: day, me: me, transcripts: transcripts, mail: mail, candidates: candidates)
        .write(to: prompt, atomically: true, encoding: .utf8)

    let log = try await runAgent(prompt: prompt)

    guard let data = try? Data(contentsOf: out) else {
        throw SyncError(description: [mailError, "The briefing agent did not write its file. Last output:\n\(log)"].compactMap { $0 }.joined(separator: "\n"))
    }
    let synthesis = try JSONDecoder().decode(Synthesis.self, from: data)
    try? FileManager.default.removeItem(at: dir.appendingPathComponent("synthesis.json"))
    try FileManager.default.moveItem(at: out, to: dir.appendingPathComponent("synthesis.json"))
    return synthesis
}

func runAgent(prompt: URL) async throws -> String {
    try await Task.detached { () throws -> String in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "cd \"$HOME\" && " + settings.briefingCommand.replacingOccurrences(of: "{prompt}", with: quoted(prompt.path))]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data.suffix(2000), as: UTF8.self)
    }.value
}
