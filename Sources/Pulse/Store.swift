import AppKit

@MainActor
final class Store: ObservableObject {
    @Published var trends = Trends()
    private var colorOrder: [String] = []
    @Published var syncing = false
    @Published var lastSync: Date?
    @Published var lastError: String?
    @Published var hasLinearKey = demoMode || linearKey() != nil
    @Published var selected: Set<String> = []
    @Published var me: String?
    @Published var today: [ActionItem] = []
    @Published var showingSettings = false
    private var todayFetched = Date.distantPast
    @Published var synthesis: Synthesis?
    @Published var synthesizedAt: Date?
    @Published var synthesizing = false
    @Published var synthesisError: String?
    @Published var doneIDs: Set<String> = []
    @Published var pinnedIDs: [String] = []
    @Published var workflow: [String: [WorkflowState]] = [:]
    private var localBranches: Set<String> = []

    let db: DB
    let dir: URL
    @Published var range = TrendRange.year {
        didSet { load() }
    }
    var buckets: [String] { range.buckets() }
    func label(_ key: String) -> String { range.label(key) }

    init(db: DB, dir: URL) {
        self.db = db
        self.dir = dir
        lastSync = db.meta("last_sync").flatMap(iso.date(from:))
        lastError = db.meta("last_error").flatMap { $0.isEmpty ? nil : $0 }
        let file = dir.appendingPathComponent("synthesis.json")
        synthesis = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Synthesis.self, from: $0) }
        if synthesis != nil {
            synthesizedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        if demoMode { try? seedDemo(db) }
        doneIDs = Set(savedIDs(doneKey))
        pinnedIDs = savedIDs(pinKey)
        load()
        if demoMode { loadDemo() }
    }

    func load() {
        do {
            trends = try db.trends(since: buckets[0], range: range, org: settings.githubOrg)
            let year = range == .year ? trends : try db.trends(since: TrendRange.year.buckets()[0], range: .year, org: settings.githubOrg)
            colorOrder = ranked(year)
            me = db.meta("me")
        } catch {
            lastError = "\(error)"
        }
    }

    var people: [String] { ranked(trends) }

    func colorIndex(_ person: String) -> Int { colorOrder.firstIndex(of: person) ?? colorOrder.count + abs(person.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) }

    private func ranked(_ t: Trends) -> [String] {
        var totals: [String: Int] = [:]
        for r in t.prs { totals[r.person, default: 0] += 1 }
        for c in t.created + t.completed { totals[c.person, default: 0] += c.n }
        return totals.keys.sorted { (totals[$0]!, $1) > (totals[$1]!, $0) }
    }

    func includes(_ person: String) -> Bool { selected.isEmpty || selected.contains(person) }

    func toggle(_ person: String) {
        if selected.contains(person) { selected.remove(person) } else { selected.insert(person) }
    }

    func refresh() async {
        guard !syncing, !demoMode else { return }
        syncing = true
        var message = ""
        do {
            try await syncGitHub(db, token: try ghToken())
            if let key = linearKey() { try await syncLinear(db, key: key) }
        } catch {
            message = "\(error)"
        }
        if let todayError = await refreshToday() { message += (message.isEmpty ? "" : "\n") + todayError }
        lastError = message.isEmpty ? nil : message
        lastSync = Date()
        try? db.setMeta("last_error", message)
        try? db.setMeta("last_sync", iso.string(from: lastSync!))
        syncing = false
        load()
    }

    @discardableResult
    func refreshToday() async -> String? {
        var errors: [String] = []
        var github: [ActionItem] = [], linear: [ActionItem] = []
        do { github = try await fetchGitHubToday(token: try ghToken()) } catch { errors.append("\(error)") }
        if let key = linearKey() {
            do { (linear, workflow) = try await fetchLinearToday(key: key) } catch { errors.append("\(error)") }
        }
        today = mergeTicketsAndPRs(github + linear)
        localBranches = localBranchNames()
        todayFetched = Date()
        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    func localBranchesForDemo(_ branches: Set<String>) { localBranches = branches }

    func refreshTodayIfStale() {
        guard !demoMode else { return }
        if Date().timeIntervalSince(todayFetched) > 300, !syncing { Task { await refreshToday() } }
    }

    func markRead(_ id: String) async {
        guard let key = linearKey() else { return }
        do {
            try await markNotificationRead(key: key, id: id)
            today.removeAll { $0.notificationID == id }
        } catch {
            lastError = "\(error)"
        }
    }

    func saveLinearKey(_ key: String) async throws {
        try await Pulse.saveLinearKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
        hasLinearKey = true
        await refresh()
    }

    private var day: String { Date().formatted(.iso8601.year().month().day()) }
    private var doneKey: String { "done-" + day }
    private var pinKey: String { "pinned-" + day }

    private func savedIDs(_ key: String) -> [String] {
        db.meta(key).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
    }

    private func saveIDs(_ ids: [String], _ key: String) {
        if let json = try? JSONEncoder().encode(ids) { try? db.setMeta(key, String(decoding: json, as: UTF8.self)) }
    }

    func toggleDone(_ id: String) {
        if doneIDs.contains(id) { doneIDs.remove(id) } else { doneIDs.insert(id) }
        saveIDs(Array(doneIDs), doneKey)
    }

    func pin(_ id: String) {
        guard !pinnedIDs.contains(id), !checklist.contains(where: { $0.id == id }) else { return }
        pinnedIDs.append(id)
        saveIDs(pinnedIDs, pinKey)
    }

    var checklist: [TodoRow] {
        let live = Dictionary(today.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard let plan = synthesis?.today, let planned = synthesizedAt, Calendar.current.isDateInToday(planned) else {
            let base = Array(today.filter { $0.kind != .notification }.prefix(6))
            let ids = Set(base.map(\.id))
            let pinned = pinnedIDs.compactMap { id in today.first { $0.id == id } }.filter { !ids.contains($0.id) }
            return (base + pinned).map { TodoRow(item: $0, why: nil, minutes: nil, done: $0.closed || doneIDs.contains($0.id)) }
        }

        let refs = Set(plan.compactMap(\.ref))
        let arrived = today.filter { $0.urgent && !refs.contains($0.id) }
            .map { TodoRow(item: $0, why: "New since the briefing", minutes: nil, done: $0.closed || doneIDs.contains($0.id)) }
        let rows = plan.compactMap { p -> TodoRow? in
            if let ref = p.ref, let item = live[ref] {
                return TodoRow(item: item, why: p.why, minutes: p.minutes, done: item.closed || doneIDs.contains(item.id))
            }
            guard let url = URL(string: p.url ?? "") ?? (p.ref.flatMap { URL(string: "https://linear.app/\(db.meta("linear_workspace") ?? "")/issue/\($0)") }) else { return nil }
            let id = p.id
            let resolved = p.ref != nil
            let item = ActionItem(id: id, kind: .followUp, title: p.title, reason: resolved ? "Done" : (p.source ?? "").capitalized,
                                  url: url, since: planned)
            return TodoRow(item: item, why: resolved ? nil : p.why, minutes: p.minutes, done: resolved || doneIDs.contains(id))
        }
        let shown = Set((arrived + rows).map(\.id))
        let pinned = pinnedIDs.compactMap { live[$0] }.filter { !shown.contains($0.id) }
            .map { TodoRow(item: $0, why: "Added today", minutes: nil, done: $0.closed || doneIDs.contains($0.id)) }
        return arrived + rows + pinned
    }

    var moreItems: [ActionItem] {
        let shown = Set(checklist.map(\.id))
        return today.filter { !shown.contains($0.id) }
    }

    func setState(_ state: WorkflowState, for item: ActionItem) async {
        guard let key = linearKey(), let issue = item.issueID else { return }
        do {
            try await moveIssue(key: key, issueID: issue, stateID: state.id)
            if let i = today.firstIndex(where: { $0.id == item.id }) {
                today[i].state = state
                today[i].started = state.type == "started"
            }
        } catch {
            lastError = "\(error)"
        }
    }

    func checkbox(done: Bool) -> NSImage {
        let states = workflow.values.flatMap { $0 }
        if let state = states.first(where: { $0.type == (done ? "completed" : "unstarted") }) { return state.image }
        return statusSymbol(done ? "checkmark.circle.fill" : "circle", done ? NSColor(red: 0.37, green: 0.42, blue: 0.82, alpha: 1) : .labelColor)
    }

    func hasLocalBranch(_ branch: String) -> Bool { localBranches.contains(branch) }

    var lastStart: Launch { db.meta("last_start").flatMap(Launch.init) ?? settings.enabledIDEs.first.map { .ide($0) } ?? .prompt }
    var lastOpen: Launch { db.meta("last_open").flatMap(Launch.init) ?? settings.enabledIDEs.first.map { .ide($0) } ?? .linear }

    func launch(_ choice: Launch, item: ActionItem) async {
        guard let ticket = item.ticket, let branch = item.branch else { return }
        if choice != .prompt { pin(item.id) }
        try? db.setMeta(item.started ? "last_open" : "last_start", choice.rawValue)
        objectWillChange.send()
        do {
            switch choice {
            case .linear:
                open(item.url, in: .linear)
            case .pr:
                if let pr = item.pr { open(pr) }
            case .prompt:
                guard let key = linearKey() else { return }
                let ctx = try await ticketContext(key: key, ticket: ticket, branch: branch)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ctx.prompt, forType: .string)
            case .ide(let ide) where item.started:
                let path = try await Task.detached { try worktree(for: branch, ticket: ticket) }.value
                localBranches.insert(branch)
                try openInIDE(ide, path: path)
            case .ide, .agent:
                guard let key = linearKey() else { return }
                let ctx = try await ticketContext(key: key, ticket: ticket, branch: branch)
                let path = try await Task.detached { try worktree(for: branch, ticket: ticket) }.value
                localBranches.insert(branch)
                if let state = ctx.startedStateID { try await moveIssue(key: key, issueID: ctx.issueID, stateID: state) }
                if let i = today.firstIndex(where: { $0.id == item.id }) {
                    today[i].started = true
                    today[i].state = workflow[item.teamID ?? ""]?.first { $0.id == ctx.startedStateID } ?? today[i].state
                }
                if case .ide(let ide) = choice {
                    try openInIDE(ide, path: path, prompt: ctx.prompt)
                } else if case .agent(let name) = choice, let agent = settings.agents.first(where: { $0.name == name }) {
                    let file = dir.appendingPathComponent("prompts/\(ticket).md")
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try ctx.prompt.write(to: file, atomically: true, encoding: .utf8)
                    try openAgentInTerminal(agent, path: path, promptFile: file)
                }
            }
        } catch {
            lastError = "\(error)"
        }
    }

    func synthesize() async {
        guard !synthesizing, !demoMode else { return }
        synthesizing = true
        synthesisError = nil
        do {
            synthesis = try await runSynthesis(dir: dir, candidates: today, me: me ?? "me")
            synthesizedAt = Date()
        } catch {
            synthesisError = "\(error)"
        }
        synthesizing = false
    }

    private var synthesisDue: Bool {
        let stale = Date().timeIntervalSince(synthesizedAt ?? .distantPast) > 20 * 3600
        return stale && Calendar.current.component(.hour, from: Date()) >= settings.briefingHour
    }

    func startHourlySync() {
        guard !demoMode else { return }
        Task {
            while true {
                await refresh()
                Updater.shared.checkIfDue()
                if synthesisDue { await synthesize() }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }
}
