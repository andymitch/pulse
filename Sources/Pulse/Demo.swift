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
            today: [
                Synthesis.Todo(ref: nil, title: "Reply to Dana about the pilot start date", why: "She needs a date for the customer kickoff", url: "message://%3Cdemo%40acme.com%3E", source: "mail", minutes: 10),
                Synthesis.Todo(ref: "https://github.com/acmecorp/web/pull/419", title: "Cache invoice totals per workspace", why: "Omar is blocked until it merges", url: nil, source: "github", minutes: 30),
                Synthesis.Todo(ref: "ACME-198", title: "Invite teammates from the onboarding checklist", why: "The launch blocker; answer the two review comments", url: nil, source: "linear", minutes: 45),
                Synthesis.Todo(ref: nil, title: "Answer Priya's question about event names", why: "She's naming the onboarding analytics events today", url: "https://acme.slack.com/archives/C1/p1", source: "slack", minutes: 10),
                Synthesis.Todo(ref: "ACME-214", title: "Add CSV export to the usage report", why: "Pilot customers asked for it in Tuesday's call", url: nil, source: "linear", minutes: 120),
                Synthesis.Todo(ref: "ACME-205", title: "Retry failed webhook deliveries with backoff", why: "Nearly done; finish the tests", url: nil, source: "linear", minutes: 60),
            ],
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
        doneIDs = ["ai-message://%3Cdemo%40acme.com%3E"]
    }
}

let demoMeetings = [
    SavedMeeting(file: URL(fileURLWithPath: "/demo/meetings/planning.md"), start: Calendar.current.date(bySettingHour: 9, minute: 30, second: 0, of: Date())!,
                 title: "Launch planning", recorded: "Recorded today at 9:30 (25 min). With Omar Reyes, Priya Shah.",
                 summary: "The team agreed to open sign-ups on November 4 if teammate invites merge this week. Omar will review the invites PR today, and Priya will name the onboarding analytics events before Friday.",
                 decisions: ["**Launch date**: sign-ups open November 4 if invites land this week", "**Analytics**: event names follow the existing `onboarding_` prefix"],
                 points: ["**Invites PR**: two review comments left, both small", "**CSV export**: pilot customers want it before launch"]),
]
