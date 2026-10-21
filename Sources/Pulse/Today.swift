import AppKit
import SwiftUI

struct ActionItem: Identifiable {
    enum Kind: Int { case failing, review, pr, followUp, ticket, notification }

    let id: String
    var kind: Kind
    let title: String
    var reason: String
    let url: URL
    var ticket: String?
    var started = false
    var branch: String?
    var pr: URL?
    var notificationID: String?
    var issueID: String?
    var teamID: String?
    var state: WorkflowState?
    var priority = 5
    let since: Date

    var urgent: Bool { kind.rawValue <= Kind.pr.rawValue }
    var closed: Bool { ["completed", "canceled", "duplicate"].contains(state?.type ?? "") }
    var summary: String { "\(kind) \(ticket ?? "") \(reason) — \(title)" }
}

private let githubToday = """
query($review: String!, $mine: String!) {
  viewer { login }
  review: search(query: $review, type: ISSUE, first: 50) { nodes { ... on PullRequest { number title url createdAt isDraft author { login } repository { name } } } }
  mine: search(query: $mine, type: ISSUE, first: 50) { nodes { ... on PullRequest { number title url createdAt isDraft headRefName mergeStateStatus reviewDecision repository { name }
    commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    reviewThreads(first: 100) { nodes { isResolved comments(last: 1) { nodes { author { login } } } } } } } }
}
"""

private let linearToday = """
{ viewer { assignedIssues(first: 100, filter: {state: {type: {in: ["started", "unstarted"]}}}) { nodes { id identifier title url priority createdAt branchName state { id name type color position } team { id } cycle { isActive } } } }
  teams(first: 50) { nodes { id states { nodes { id name type color position } } } }
  notifications(first: 50) { nodes { id type readAt createdAt actor { name } ... on IssueNotification { issue { identifier title url } } } } }
"""

private struct GitHubToday: Decodable {
    struct Login: Decodable { let login: String }
    struct Repo: Decodable { let name: String }
    struct Review: Decodable {
        let number: Int?
        let title, url, createdAt: String?
        let isDraft: Bool?
        let author: Login?
        let repository: Repo?
    }
    struct Mine: Decodable {
        struct Commit: Decodable { struct C: Decodable { struct R: Decodable { let state: String }; let statusCheckRollup: R? }; let commit: C }
        struct Thread: Decodable { struct Comment: Decodable { let author: Login? }; let isResolved: Bool; let comments: Nodes<Comment> }
        let number: Int?
        let title, url, createdAt, headRefName, mergeStateStatus, reviewDecision: String?
        let isDraft: Bool?
        let repository: Repo?
        let commits: Nodes<Commit>?
        let reviewThreads: Nodes<Thread>?
    }
    let viewer: Login
    let review: Nodes<Review>
    let mine: Nodes<Mine>
}

private struct LinearToday: Decodable {
    struct Issue: Decodable {
        struct Cycle: Decodable { let isActive: Bool }
        struct Team: Decodable { let id: String }
        let id, identifier, title, url, createdAt, branchName: String
        let priority: Int
        let state: WorkflowState
        let team: Team
        let cycle: Cycle?
    }
    struct TeamStates: Decodable { let id: String; let states: Nodes<WorkflowState> }
    struct Notification: Decodable {
        struct Ref: Decodable { let identifier, title, url: String }
        let id, type, createdAt: String
        let readAt: String?
        let actor: Named?
        let issue: Ref?
    }
    struct Viewer: Decodable { let assignedIssues: Nodes<Issue> }
    let viewer: Viewer
    let teams: Nodes<TeamStates>
    let notifications: Nodes<Notification>
}

func statusSymbol(_ name: String, _ color: NSColor) -> NSImage {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) else { return NSImage() }
    let image = NSImage(size: base.size, flipped: false) { rect in
        base.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    image.isTemplate = false
    return image
}

struct WorkflowState: Decodable, Hashable {
    let id, name, type, color: String
    let position: Double

    var symbol: String {
        switch type {
        case "backlog": "circle.dashed"
        case "unstarted": "circle"
        case "started": name.localizedCaseInsensitiveContains("review") ? "circle.inset.filled" : "circle.lefthalf.filled"
        case "completed": "checkmark.circle.fill"
        case "canceled", "duplicate": "xmark.circle.fill"
        default: "questionmark.circle"
        }
    }

    var image: NSImage {
        let v = Int(color.dropFirst(), radix: 16) ?? 0x888888
        return statusSymbol(symbol, NSColor(red: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1))
    }

    static let order = ["triage", "backlog", "unstarted", "started", "completed", "canceled", "duplicate"]
}

private let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private func date(_ s: String?) -> Date {
    guard let s else { return Date() }
    return iso.date(from: s) ?? isoFrac.date(from: s) ?? Date()
}

private let priorityNames = [1: "Urgent", 2: "High", 3: "Medium", 4: "Low"]

func prReasons(ci: String?, mergeState: String?, decision: String?, unanswered: Int) -> (failing: Bool, reasons: [String]) {
    var reasons: [String] = []
    let failing = ci == "FAILURE" || ci == "ERROR"
    if failing { reasons.append("CI failing") }
    if decision == "CHANGES_REQUESTED" { reasons.append("Changes requested") }
    if unanswered > 0 { reasons.append("\(unanswered) unanswered thread\(unanswered == 1 ? "" : "s")") }
    if mergeState == "DIRTY" { reasons.append("Merge conflicts") }
    if mergeState == "BEHIND" { reasons.append("Behind main") }
    if decision == "APPROVED" && reasons.isEmpty && ci == "SUCCESS" { reasons.append("Approved, ready to merge") }
    return (failing, reasons)
}

func fetchGitHubToday(token: String) async throws -> [ActionItem] {
    let scope = "is:open is:pr archived:false org:\(settings.githubOrg)"
    let d: GitHubToday = try await gql(githubURL, auth: "bearer \(token)", githubToday,
                                       ["review": "\(scope) review-requested:@me", "mine": "\(scope) author:@me"])
    var items: [ActionItem] = []
    for pr in d.review.nodes where pr.isDraft == false {
        guard let url = pr.url.flatMap(URL.init) else { continue }
        items.append(ActionItem(id: url.absoluteString, kind: .review, title: pr.title ?? "",
                                reason: "Review requested by \(pr.author?.login ?? "someone") · \(pr.repository?.name ?? "")#\(pr.number ?? 0)",
                                url: url, pr: url, since: date(pr.createdAt)))
    }
    for pr in d.mine.nodes {
        guard let url = pr.url.flatMap(URL.init) else { continue }
        let ci = pr.commits?.nodes.first?.commit.statusCheckRollup?.state
        let replies = (pr.reviewThreads?.nodes ?? []).filter { !$0.isResolved && $0.comments.nodes.last?.author?.login != d.viewer.login }.count
        let (failing, reasons) = prReasons(ci: ci, mergeState: pr.mergeStateStatus, decision: pr.reviewDecision, unanswered: replies)
        items.append(ActionItem(id: url.absoluteString, kind: failing ? .failing : reasons.isEmpty ? .followUp : .pr, title: pr.title ?? "",
                                reason: (reasons.isEmpty ? ["Waiting on review"] : reasons).joined(separator: " · ") + " · \(pr.repository?.name ?? "")#\(pr.number ?? 0)",
                                url: url, started: true, branch: pr.headRefName, pr: url, since: date(pr.createdAt)))
    }
    return items
}

func fetchLinearToday(key: String) async throws -> (items: [ActionItem], workflow: [String: [WorkflowState]]) {
    let d: LinearToday = try await gql(linearURL, auth: key, linearToday)
    let tickets = d.viewer.assignedIssues.nodes
        .filter { $0.state.type == "started" || $0.cycle?.isActive == true }
        .compactMap { i -> ActionItem? in
            guard let url = URL(string: i.url) else { return nil }
            let reason = [i.identifier, priorityNames[i.priority]].compactMap { $0 }.joined(separator: " · ")
            return ActionItem(id: i.identifier, kind: .ticket, title: i.title, reason: reason, url: url, ticket: i.identifier,
                              started: i.state.type == "started", branch: i.branchName, issueID: i.id, teamID: i.team.id, state: i.state,
                              priority: i.priority == 0 ? 5 : i.priority, since: date(i.createdAt))
        }
    let weekAgo = Date().addingTimeInterval(-7 * 86400)
    let notes = d.notifications.nodes.compactMap { n -> ActionItem? in
        guard n.readAt == nil, let issue = n.issue, let url = URL(string: issue.url), date(n.createdAt) > weekAgo else { return nil }
        let what = n.type.dropFirst("issue".count).reduce("") { $0 + ($1.isUppercase ? " " + $1.lowercased() : String($1)) }
        return ActionItem(id: n.id, kind: .notification, title: issue.title,
                          reason: "\(issue.identifier) ·\(what)" + (n.actor.map { " by \($0.name)" } ?? ""),
                          url: url, notificationID: n.id, since: date(n.createdAt))
    }
    let workflow = Dictionary(uniqueKeysWithValues: d.teams.nodes.map { team in
        (team.id, team.states.nodes.sorted { (WorkflowState.order.firstIndex(of: $0.type) ?? 9, $0.position) < (WorkflowState.order.firstIndex(of: $1.type) ?? 9, $1.position) })
    })
    return (tickets + notes, workflow)
}

func mergeTicketsAndPRs(_ items: [ActionItem]) -> [ActionItem] {
    let prs = items.filter { $0.pr != nil && $0.kind != .review }
    var used = Set<String>()
    var merged = items.compactMap { item -> ActionItem? in
        guard item.kind == .ticket, let ticket = item.ticket?.lowercased() else { return item.pr != nil && item.kind != .review ? nil : item }
        var item = item
        if let pr = prs.first(where: { ($0.branch ?? "").lowercased().hasPrefix(ticket) || $0.title.lowercased().contains(ticket) }) {
            used.insert(pr.id)
            item.pr = pr.pr
            item.branch = pr.branch ?? item.branch
            item.started = true
            item.kind = pr.kind == .followUp ? .ticket : pr.kind
            item.reason += " · " + pr.reason
        }
        return item
    }
    merged += prs.filter { !used.contains($0.id) }
    return merged.sorted { ($0.kind.rawValue, $0.priority, $0.since) < ($1.kind.rawValue, $1.priority, $1.since) }
}

func markNotificationRead(key: String, id: String) async throws {
    struct R: Decodable { struct U: Decodable { let success: Bool }; let notificationUpdate: U }
    let _: R = try await gql(linearURL, auth: key, "mutation($id: String!, $at: DateTime!) { notificationUpdate(id: $id, input: {readAt: $at}) { success } }",
                             ["id": id, "at": iso.string(from: Date())])
}

struct TicketContext {
    let prompt, issueID: String
    let startedStateID: String?
}

func ticketContext(key: String, ticket: String, branch: String) async throws -> TicketContext {
    struct D: Decodable {
        struct Issue: Decodable {
            struct Parent: Decodable { let identifier, title: String }
            struct Comment: Decodable { let body: String; let user: Named? }
            struct State: Decodable { let id, name: String; let position: Double }
            struct Team: Decodable { let states: Nodes<State> }
            let id, identifier, title, url: String
            let description: String?
            let parent: Parent?
            let comments: Nodes<Comment>
            let team: Team
        }
        let issue: Issue
    }
    let d: D = try await gql(linearURL, auth: key, """
        query($id: String!) { issue(id: $id) { id identifier title url description parent { identifier title }
          comments(last: 10) { nodes { body user { name } } }
          team { states(filter: {type: {eq: "started"}}) { nodes { id name position } } } } }
        """, ["id": ticket])
    let i = d.issue
    var parts = ["Implement \(i.identifier): \(i.title)\n\(i.url)"]
    if let p = i.parent { parts.append("Parent: \(p.identifier) \(p.title)") }
    if let desc = i.description, !desc.isEmpty { parts.append("## Description\n\(desc)") }
    let comments = i.comments.nodes.map { "- \($0.user?.name ?? "Someone"): \($0.body)" }
    if !comments.isEmpty { parts.append("## Comments\n" + comments.joined(separator: "\n")) }
    parts.append("Work on branch \(branch) in its own worktree of the \(settings.repoName) repo.")
    let states = i.team.states.nodes
    let started = states.first { $0.name == "In Progress" } ?? states.min { $0.position < $1.position }
    return TicketContext(prompt: parts.joined(separator: "\n\n"), issueID: i.id, startedStateID: started?.id)
}

func moveIssue(key: String, issueID: String, stateID: String) async throws {
    struct R: Decodable { struct U: Decodable { let success: Bool }; let issueUpdate: U }
    let _: R = try await gql(linearURL, auth: key, "mutation($id: String!, $state: String!) { issueUpdate(id: $id, input: {stateId: $state}) { success } }",
                             ["id": issueID, "state": stateID])
}

struct TodoRow: Identifiable {
    let item: ActionItem
    let why: String?
    let minutes: Int?
    let done: Bool
    var id: String { item.id }
}

struct TodayView: View {
    @ObservedObject var store: Store
    @State private var showMore = false

    var body: some View {
        let rows = store.checklist
        let left = rows.filter { !$0.done }.compactMap(\.minutes).reduce(0, +)
        Panel(title: "Today · \(rows.filter(\.done).count) of \(rows.count) done", accessory: {
            if left > 0 { Text("about \(duration(left)) left").font(.caption).foregroundStyle(.secondary) }
        }) {
            if rows.isEmpty {
                Text(store.syncing ? "Loading…" : "Nothing needs you right now.").foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                TodoRowView(store: store, row: row)
                if row.id != rows.last?.id { Divider() }
            }
        }
        let more = store.moreItems
        if !more.isEmpty {
            DisclosureGroup("More · \(more.count)", isExpanded: $showMore) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(more) { item in
                        TodoRowView(store: store, row: TodoRow(item: item, why: nil, minutes: nil, done: false), checkable: false)
                    }
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 14)
            .foregroundStyle(.secondary)
        }
    }
}

private func duration(_ minutes: Int) -> String {
    minutes < 60 ? "\(minutes)m" : minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
}

private struct TodoRowView: View {
    @ObservedObject var store: Store
    let row: TodoRow
    var checkable = true

    var body: some View {
        let item = row.item
        HStack(alignment: .top, spacing: 10) {
            if let state = item.state, let team = item.teamID {
                StatusMenu(store: store, item: item, state: state, states: store.workflow[team] ?? [state]).frame(width: 16, height: 17)
            } else if checkable {
                Button { store.toggleDone(item.id) } label: {
                    Image(nsImage: store.checkbox(done: row.done))
                }
                .buttonStyle(.plain)
                .frame(width: 16, height: 17)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(2).strikethrough(row.done).foregroundStyle(row.done ? .secondary : .primary)
                Text([row.why, item.reason, row.minutes.map { "~" + duration($0) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if !row.done { Buttons(store: store, item: item) }
        }
    }
}

enum Launch: Hashable {
    case ide(IDE), agent(String), prompt, pr, linear

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "ide": guard let ide = IDE(rawValue: parts.last ?? "") else { return nil }; self = .ide(ide)
        case "agent": self = .agent(parts.last ?? "")
        case "prompt": self = .prompt
        case "pr": self = .pr
        case "linear": self = .linear
        default: return nil
        }
    }

    var rawValue: String {
        switch self {
        case .ide(let ide): "ide:\(ide.rawValue)"
        case .agent(let name): "agent:\(name)"
        case .prompt: "prompt"
        case .pr: "pr"
        case .linear: "linear"
        }
    }

    var brand: Brand? {
        switch self {
        case .ide(let ide): ide.brand
        case .agent(let name): settings.agents.first { $0.name == name }?.brand
        case .pr: .github
        case .linear: .linear
        case .prompt: nil
        }
    }

    var symbol: String { self == .prompt ? "doc.on.clipboard" : "terminal" }

    var name: String {
        switch self {
        case .ide(let ide): ide.name
        case .agent(let name): name
        case .prompt: "Copy as prompt"
        case .pr: "GitHub PR"
        case .linear: "Linear"
        }
    }
}

private struct StatusMenu: View {
    @ObservedObject var store: Store
    let item: ActionItem
    let state: WorkflowState
    let states: [WorkflowState]

    var body: some View {
        Menu {
            ForEach(states, id: \.id) { s in
                Button { Task { await store.setState(s, for: item) } } label: {
                    Label { Text(s.name) } icon: { Image(nsImage: s.image) }
                }
                .disabled(s.id == state.id)
            }
        } label: {
            Image(nsImage: state.image)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(state.name)
    }
}

private struct Buttons: View {
    @ObservedObject var store: Store
    let item: ActionItem

    var body: some View {
        HStack(spacing: 6) {
            if item.ticket != nil, item.branch != nil {
                TicketButton(store: store, item: item)
            } else if let pr = item.pr {
                AppButton(.github, item.kind == .review ? "Review" : "Open", help: "Open the PR") { store.pin(item.id); open(pr) }
            } else {
                let slack = item.url.host?.hasSuffix("slack.com") == true
                let linear = item.url.host == "linear.app"
                AppButton(slack ? .slack : linear ? .linear : nil, "Open", symbol: item.url.scheme == "message" ? "envelope" : "arrow.up.right.square") { store.pin(item.id); open(item.url, in: slack ? .slack : linear ? .linear : nil) }
            }
            if let id = item.notificationID { AppButton(nil, "Mark read", icon: false) { await store.markRead(id) } }
        }
    }
}

private struct TicketButton: View {
    @ObservedObject var store: Store
    let item: ActionItem

    private var ides: [Launch] { settings.enabledIDEs.map { .ide($0) } }
    private var agents: [Launch] { settings.enabledAgents.map { .agent($0.name) } }

    private var choices: [Launch] {
        item.started ? ides + (item.pr != nil ? [.pr] : []) + [.linear] : ides + agents + [.prompt, .linear]
    }

    private var primary: Launch {
        let last = item.started ? store.lastOpen : store.lastStart
        return choices.contains(last) ? last : choices[0]
    }

    private func label(_ l: Launch) -> String {
        l == .prompt ? "Copy prompt" : item.started || l == .linear ? "Open" : "Start"
    }

    var body: some View {
        Menu {
            if item.started {
                Section("Open in") { ForEach(choices, id: \.self) { menuItem($0) } }
                Divider()
                menuItem(.prompt)
            } else {
                menuItem(.prompt)
                if !ides.isEmpty { Section("Start in") { ForEach(ides, id: \.self) { menuItem($0) } } }
                if !agents.isEmpty { Section("Start in \(terminalName)") { ForEach(agents, id: \.self) { menuItem($0) } } }
                Divider()
                menuItem(.linear)
            }
        } label: {
            Label { Text(label(primary)) } icon: { icon(primary) }
        } primaryAction: {
            Task { await store.launch(primary, item: item) }
        }
        .menuStyle(.button)
        .fixedSize()
        .help(item.started ? "Open in \(primary.name)" : primary == .prompt ? "Copy the agent prompt" : isAgent(primary) ? "Start \(primary.name) in \(terminalName)" : "Start in \(primary.name)")
    }

    @ViewBuilder private func icon(_ l: Launch) -> some View {
        if let brand = l.brand { Image(nsImage: brand.image(size: 13)) } else { Image(systemName: l.symbol).font(.system(size: 12)).frame(width: 13, height: 13) }
    }

    private func isAgent(_ l: Launch) -> Bool {
        if case .agent = l { return true }
        return false
    }

    private func menuItem(_ l: Launch) -> some View {
        Button { Task { await store.launch(l, item: item) } } label: {
            Label { Text(l == .linear && !item.started ? "Open in Linear" : l.name) } icon: { icon(l) }
        }
    }
}

private struct AppButton: View {
    let brand: Brand?
    let label: String?
    let help: String
    let icon: Bool
    let action: () async -> Void

    var symbol = "arrow.up.right.square"

    init(_ brand: Brand?, _ label: String? = nil, help: String = "", icon: Bool = true, symbol: String = "arrow.up.right.square", action: @escaping () async -> Void) {
        self.symbol = symbol
        self.brand = brand
        self.label = label
        self.help = help
        self.icon = icon
        self.action = action
    }

    @ViewBuilder private var iconView: some View {
        if let brand { Image(nsImage: brand.image(size: 13)) } else if icon { Image(systemName: symbol).font(.system(size: 12)).frame(width: 13, height: 13) }
    }

    var body: some View {
        Button { Task { await action() } } label: {
            if let label {
                Label { Text(label) } icon: { iconView }
            } else {
                iconView
            }
        }
        .buttonStyle(.bordered)
        .help(help)
    }
}

struct Chip: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(configuration.isPressed ? 1 : 0.6), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(RoundedRectangle(cornerRadius: 5))
    }
}
