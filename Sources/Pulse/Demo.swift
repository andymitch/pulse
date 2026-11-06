import Foundation

let demoMode = CommandLine.arguments.contains("--demo")

extension Settings {
    static var demo: Settings {
        var s = Settings()
        s.githubOrg = "acmecorp"
        s.githubAccount = "jane-acme"
        s.repoPath = "~/code/acme"
        s.slackChannels = [SlackChannel(id: "C1", name: "engineering"), SlackChannel(id: "C2", name: "launch")]
        s.mail = true
        s.ides = [.zed, .cursor]
        s.voiceAsked = true
        return s
    }
}

private let people = [("Jane Doe", "jane"), ("Omar Reyes", "omar"), ("Priya Shah", "priya"), ("Sam Lee", "sam"), ("Kai Chen", "kai")]

private let states = [
    WorkflowState(id: "s-backlog", name: "Backlog", type: "backlog", color: "#bec2c8", position: 0),
    WorkflowState(id: "s-todo", name: "Todo", type: "unstarted", color: "#e2e2e2", position: 1),
    WorkflowState(id: "s-progress", name: "In Progress", type: "started", color: "#f2c94c", position: 2),
    WorkflowState(id: "s-review", name: "In Review", type: "started", color: "#4cb782", position: 3),
    WorkflowState(id: "s-done", name: "Done", type: "completed", color: "#5e6ad2", position: 4),
    WorkflowState(id: "s-canceled", name: "Canceled", type: "canceled", color: "#95a2b3", position: 5),
]

func seedDemo(_ db: DB) throws {
    var cal = Calendar(identifier: .iso8601)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let now = Date()
    try db.transaction {
        for (name, handle) in people {
            try db.query("INSERT OR REPLACE INTO users VALUES (?, ?)", [name, "\(handle)@acme.com"])
        }
        try db.setMeta("me", "Jane Doe")
        try db.setMeta("linear_workspace", "acme")
        var pr = 1, issue = 1
        for back in (0..<365).reversed() {
            let day = cal.date(byAdding: .day, value: -back, to: now)!
            let weekday = cal.component(.weekday, from: day)
            guard weekday != 1 && weekday != 7 else { continue }
            let growth = Double(365 - back) / 365
            for (p, (name, handle)) in people.enumerated() {
                let rate = [1.1, 0.9, 1.3, 0.6, 0.8][p] * (0.6 + growth)
                let n = Int(rate + Double((back * 7 + p * 13) % 10) / 10)
                for k in 0..<n {
                    let created = cal.date(byAdding: .minute, value: -(90 + ((k * 7 + p * 11 + back * 13) % 47) * 37), to: day)!
                    try db.query("INSERT INTO prs VALUES ('web', ?, ?, ?, ?, ?)",
                                 [pr, "\(handle)-acme", iso.string(from: created), iso.string(from: day), 40 + (pr * 37) % 620])
                    pr += 1
                }
                let opened = (back + p) % 3 == 0 ? 2 : (back + p) % 2
                for _ in 0..<opened {
                    let done = issue % 5 != 0 && back > 1 ? iso.string(from: cal.date(byAdding: .day, value: min(back, 1 + issue % 6), to: day)!) : nil
                    try db.query("INSERT INTO issues VALUES (?, ?, 'Demo', '', ?, ?, ?, ?)",
                                 ["i\(issue)", "ACME-\(issue)", name, people[(p + issue) % people.count].0, iso.string(from: day), done])
                    issue += 1
                }
            }
        }
        try db.set(["Self-serve onboarding", "Billing v2"], "linear_projects")
    }
    try seedDemoFacts(db, now: now)
}

private func seedDemoFacts(_ db: DB, now: Date) throws {
    let day = { (back: Int) in Calendar.current.date(byAdding: .day, value: -back, to: now)!.formatted(localDay) }
    let sources: [FactChanges.Source] = [
        .init(id: 1, kind: "slack", url: "https://acme.slack.com/archives/C2/p1", title: "Omar in #launch: launch checklist", author: "Omar Reyes", date: day(1), excerpt: nil),
        .init(id: 2, kind: "linear", url: "https://linear.app/acme/issue/ACME-198", title: "ACME-198 Invite teammates from the onboarding checklist", author: "Jane Doe", date: day(1), excerpt: nil),
        .init(id: 3, kind: "meeting", url: "file:///demo/meetings/planning.md", title: "Launch planning", author: nil, date: day(0), excerpt: nil),
        .init(id: 4, kind: "github", url: "https://github.com/acmecorp/web/pull/412", title: "Invite teammates from the checklist (web#412)", author: "Jane Doe", date: day(0), excerpt: nil),
        .init(id: 5, kind: "linear", url: "https://linear.app/acme/issue/ACME-214", title: "ACME-214 Add CSV export to the usage report", author: "Jane Doe", date: day(2), excerpt: nil),
    ]
    let fact = { (subject: String, kind: String, text: String, back: Int, sources: [Int]) in
        FactChanges.Add(subject: .init(kind: "topic", name: subject, aliases: nil), kind: kind, text: text, observed: day(back), sources: sources, supersedes: nil)
    }
    _ = try applyFacts(FactChanges(sources: sources, add: [
        fact("Self-serve onboarding", "decision", "Sign-ups open November 4 if teammate invites merge this week.", 0, [3, 1]),
        fact("Self-serve onboarding", "status", "The checklist, sample data and billing step are live behind a flag.", 2, [1]),
        fact("ACME-198", "status", "Invites are blocked on the role picker design.", 3, [2]),
        fact("ACME-214", "commitment", "Jane promised the pilot customers a CSV export of the usage report before launch.", 2, [5]),
        fact("Priya Shah", "owner", "Priya Shah owns the onboarding analytics events and names them before Friday.", 0, [3]),
    ], confirm: nil), to: db, now: now)
    let blocked = try db.query("SELECT id FROM facts WHERE text LIKE 'Invites are blocked%'").first?[0] as? Int
    _ = try applyFacts(FactChanges(sources: sources, add: [
        FactChanges.Add(subject: .init(kind: "ticket", name: "ACME-198", aliases: nil), kind: "status",
                        text: "The invites PR (web#412) is waiting on review with two small comments left; the role picker uses the inviter's role.", observed: day(0), sources: [4, 2], supersedes: blocked.map { [$0] }),
    ], confirm: nil), to: db, now: now)
    _ = try applyFacts(FactChanges(sources: nil, add: [
        FactChanges.Add(subject: .init(kind: "project", name: "Billing v2", aliases: nil), kind: "decision",
                        text: "Billing v2 moves annual plans to invoicing in December, after the onboarding launch.", observed: day(0), sources: [], supersedes: nil),
    ], confirm: nil), to: db, now: now, origin: "agent")
    if let billing = try db.query("SELECT id FROM facts WHERE text LIKE 'Billing v2 moves%'").first?[0] as? Int {
        _ = try applyFacts(FactChanges(sources: nil, add: nil, confirm: nil, doubt: [.init(id: billing, reason: "Omar said in #launch that invoicing waits until January; nothing says which is current.")]), to: db, now: now)
    }
}

@MainActor
extension Store {
    func loadDemo() {
        let url = { (s: String) in URL(string: s)! }
        let ago = { (h: Double) in Date().addingTimeInterval(-h * 3600) }
        today = [
            ActionItem(id: "ACME-198", kind: .ticket, title: "Invite teammates from the onboarding checklist", reason: "ACME-198 · High · Waiting on review · web#412",
                       url: url("https://linear.app/acme/issue/ACME-198"), ticket: "ACME-198", started: true, branch: "acme-198-invite-teammates",
                       pr: url("https://github.com/acmecorp/web/pull/412"), issueID: "1", teamID: "T", state: states[3], priority: 2, since: ago(30)),
            ActionItem(id: "https://github.com/acmecorp/web/pull/419", kind: .review, title: "Cache invoice totals per workspace",
                       reason: "Review requested by omar-acme · web#419", url: url("https://github.com/acmecorp/web/pull/419"),
                       pr: url("https://github.com/acmecorp/web/pull/419"), since: ago(5)),
            ActionItem(id: "ACME-214", kind: .ticket, title: "Add CSV export to the usage report", reason: "ACME-214 · High",
                       url: url("https://linear.app/acme/issue/ACME-214"), ticket: "ACME-214", branch: "acme-214-csv-export",
                       issueID: "2", teamID: "T", state: states[1], priority: 2, since: ago(50)),
            ActionItem(id: "ACME-205", kind: .ticket, title: "Retry failed webhook deliveries with backoff", reason: "ACME-205 · Medium",
                       url: url("https://linear.app/acme/issue/ACME-205"), ticket: "ACME-205", started: true, branch: "acme-205-webhook-retries",
                       issueID: "3", teamID: "T", state: states[2], priority: 3, since: ago(70)),
            ActionItem(id: "ACME-221", kind: .ticket, title: "Empty state for the new projects page", reason: "ACME-221 · Low",
                       url: url("https://linear.app/acme/issue/ACME-221"), ticket: "ACME-221", branch: "acme-221-empty-state",
                       issueID: "4", teamID: "T", state: states[1], priority: 4, since: ago(90)),
        ]
        workflow = ["T": states]
        localBranchesForDemo(["acme-198-invite-teammates", "acme-205-webhook-retries"])
        synthesis = Synthesis(
            focus: [Synthesis.Focus(
                headline: "Ship self-serve onboarding before the November launch",
                summary: "The goal is **new workspaces that set themselves up without a sales call**, so the launch can open sign-ups to everyone. The checklist, sample data and billing step are live behind a flag, and *Priya* is wiring the analytics. **The blocker is invites**: teammates can't be added from the checklist yet, which is `ACME-198`, your PR waiting on review. **Your part is landing `ACME-198` this week**, then the CSV export (`ACME-214`) that the first pilot customers asked for.",
                sources: [1, 2, 3, 4])],
            sources: [
                Synthesis.Source(id: 1, title: "Omar in #launch: launch checklist", url: "https://acme.slack.com/archives/C2/p1", kind: "slack", author: "Omar Reyes", date: "2026-10-20",
                                 excerpt: "Everything on the list is green except teammate invites. If that lands this week we can open sign-ups on the 4th."),
                Synthesis.Source(id: 2, title: "Self-serve onboarding spec", url: "https://linear.app/acme/document/onboarding", kind: "doc", author: "Priya Shah", date: "2026-10-14",
                                 excerpt: "A new workspace should reach its first report in under ten minutes, with no help from us."),
                Synthesis.Source(id: 3, title: "Weekly planning, Oct 21", url: "file:///demo/planning.txt", kind: "meeting", author: nil, date: "2026-10-21",
                                 excerpt: "Invites are the last launch blocker. Jane owns it; Omar reviews today."),
                Synthesis.Source(id: 4, title: "ACME-198 Invite teammates from the onboarding checklist", url: "https://linear.app/acme/issue/ACME-198", kind: "linear", author: "Jane Doe", date: "2026-10-20",
                                 excerpt: "Send invites from step 3 of the checklist, with the inviter's role as the default."),
            ])
        synthesizedAt = Calendar.current.date(bySettingHour: 7, minute: 5, second: 0, of: Date())
        lastSync = Date().addingTimeInterval(-90)
        let demoTasks = [
            PulseTask(id: "demo-dana", title: "Reply to Dana about the pilot start date", why: "She needs a date for the customer kickoff", url: "message://%3Cdemo%40acme.com%3E", source: "mail"),
            PulseTask(id: "demo-priya", title: "Answer Priya's question about event names", why: "She's naming the onboarding analytics events today", url: "https://acme.slack.com/archives/C08ACME1234/p1761234567123456", source: "slack",
                      reply: "Let's keep the existing `onboarding_` prefix, so `onboarding_step_completed` and `onboarding_invite_sent`. I'll add them to the tracking plan."),
            PulseTask(id: "demo-omar", title: "Send Omar the pilot list before Friday", why: "You said you would in launch planning", url: "https://acme.slack.com/archives/C2/p1761234599000100", source: "meeting"),
        ]
        for task in demoTasks { try? db.saveTask(task) }
        try? db.mark("demo-dana", done: Date().formatted(localDay))
        reloadDay()
        let cal = Calendar(identifier: .iso8601)
        let monday = thisMonday
        doneThisWeek = [
            (0, "ACME-187", "Show plan limits on the billing page", "ACME-187 · Medium"),
            (0, "https://github.com/acmecorp/web/pull/401", "Speed up the usage report query", "Review requested by priya-acme · web#401"),
            (1, "ACME-192", "Sample data for new workspaces", "ACME-192 · High"),
        ].compactMap { offset, id, title, source in
            let date = cal.date(byAdding: .day, value: offset, to: monday)!
            guard date < cal.startOfDay(for: Date()) else { return nil }
            return DoneItem(id: id, title: title, url: url(id.hasPrefix("http") ? id : "https://linear.app/acme/issue/\(id)"), source: source, day: date.formatted(localDay))
        }
    }
}

let demoMeetings = [
    SavedMeeting(file: URL(fileURLWithPath: "/demo/meetings/planning.md"), start: Calendar.current.date(bySettingHour: 9, minute: 30, second: 0, of: Date())!,
                 title: "Launch planning", recorded: "Recorded today at 9:30 (25 min). With Omar Reyes, Priya Shah.",
                 summary: "The team agreed to open sign-ups on November 4 if teammate invites merge this week. Omar will review the invites PR today, and Priya will name the onboarding analytics events before Friday.",
                 decisions: ["**Launch date**: sign-ups open November 4 if invites land this week", "**Analytics**: event names follow the existing `onboarding_` prefix"],
                 points: ["**Invites PR**: two review comments left, both small", "**CSV export**: pilot customers want it before launch"]),
]
