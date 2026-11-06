import AppKit

@MainActor
final class Store: ObservableObject {
    @Published var trends = Trends()
    private var colorOrder: [String] = []
    @Published var myMonth: (totals: [Int], days: Int) = ([], 30)
    @Published var syncing = false
    @Published var lastSync: Date?
    @Published var lastError: String?
    @Published var hasLinearKey = demoMode || linearKey() != nil
    @Published var selected: Set<String> = []
    @Published var metric = TrendMetric.prs {
        didSet { selected = []; load() }
    }
    @Published var me: String?
    @Published var today: [ActionItem] = []
    @Published var showingSettings = false
    @Published var page = PulseTab.home
    private var todayFetched = Date.distantPast
    @Published var synthesis: Synthesis?
    @Published var synthesizedAt: Date?
    @Published var synthesizing = false
    @Published var synthesisError: String?
    @Published var tasks: [PulseTask] = []
    @Published var doneIDs: [String: String] = [:]
    @Published var laterIDs: Set<String> = []
    @Published var removedIDs: [String: String] = [:]
    @Published var doneThisWeek: [DoneItem] = []
    @Published var workflow: [String: [WorkflowState]] = [:]
    @Published var doubts: [[String: Any]] = []
    @Published var factsVersion = 0
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
        loadDay()
        load()
        if demoMode { loadDemo() }
    }

    func load() {
        do {
            trends = try db.trends(since: buckets[0], range: range)
            let year = range == .year ? trends : try db.trends(since: TrendRange.year.buckets()[0], range: .year)
            colorOrder = ranked(year)
            me = db.meta("me")
            myMonth = monthPace(db.merged(since: Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date(), author: settings.githubAccount))
        } catch {
            lastError = "\(error)"
        }
    }

    var people: [String] { ranked(trends) }

    func colorIndex(_ person: String) -> Int { colorOrder.firstIndex(of: person) ?? colorOrder.count + abs(person.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) }

    private func ranked(_ t: Trends) -> [String] {
        let counts = metric == .prs ? t.prs.map { ($0.person, 1) } : t.completed.map { ($0.person, $0.n) }
        let totals = Dictionary(counts, uniquingKeysWith: +)
        return totals.keys.sorted { (totals[$0]!, $1) > (totals[$1]!, $0) }
    }

    var meInTrends: String? { metric == .prs ? (settings.githubAccount.isEmpty ? nil : settings.githubAccount) : me }

    func includes(_ person: String) -> Bool { selected.isEmpty || selected.contains(person) }

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
        if loadedDay != day { loadDay() }
        var errors: [String] = []
        var github: [ActionItem] = [], linear: [ActionItem] = []
        do { github = try await fetchGitHubToday(token: try ghToken()) } catch { errors.append("\(error)") }
        if let key = linearKey() {
            do { (linear, workflow) = try await fetchLinearToday(key: key) } catch { errors.append("\(error)") }
        }
        today = mergeTicketsAndPRs(github + linear)
        localBranches = localBranchNames()
        todayFetched = Date()
        fetchedOK = errors.isEmpty
        recordDone()
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

    private var day: String { Date().formatted(localDay) }
    private var loadedDay = ""

    private func loadDay() {
        loadedDay = day
        loadTasks()
        doneThisWeek = db.decode(weekKey) ?? []
        let monday = thisMonday.formatted(localDay)
        let old = Set(tasks.map(\.id).filter { (doneIDs[$0] ?? removedIDs[$0] ?? monday) < monday })
        if !old.isEmpty { write { try db.deleteTasks(old) } }
        reloadFacts()
    }

    private func loadTasks() {
        tasks = db.tasks()
        let marks = db.marks()
        doneIDs = marks.done
        laterIDs = marks.later
        removedIDs = marks.removed
    }

    private func write(_ change: () throws -> Void) {
        do { try change() } catch { lastError = "\(error)" }
        loadTasks()
    }

    var openTasks: [PulseTask] { tasks.filter { doneIDs[$0.id] == nil && removedIDs[$0.id] == nil } }

    func applyTasks(_ changes: TaskChanges) {
        loadTasks()
        let (updated, closed) = applyTaskChanges(changes, to: tasks, open: Set(openTasks.map(\.id)))
        write {
            for task in updated where !tasks.contains(task) { try db.saveTask(task) }
            for id in closed where doneIDs[id] == nil { try db.mark(id, done: day) }
        }
        recordDone()
    }

    var toDoCount: Int { checklist.filter { !$0.done && $0.item.toDo }.count }

    private var doubtIDs: [String] { doubts.compactMap { ($0["id"] as? Int).map(String.init) } }

    var triageWaiting: Bool { !Set(doubtIDs).isSubset(of: db.ids("triage_seen")) }

    func checkTriage() {
        try? db.set(doubtIDs, "triage_seen")
        reloadFacts()
    }

    func reloadFacts() {
        doubts = (try? doubtedFacts(db)) ?? []
        factsVersion += 1
    }

    func confirm(fact id: Int, text: String? = nil) {
        do { try confirmFact(db, id: id, text: text) } catch { lastError = "\(error)" }
        reloadFacts()
    }

    func reject(fact id: Int) {
        do { try rejectFact(db, id: id) } catch { lastError = "\(error)" }
        reloadFacts()
    }

    private var weekKey: String { "week-" + thisMonday.formatted(localDay) }
    var fetchedOK = false

    func reloadDay() {
        loadDay()
        recordDone()
    }

    var earlierThisWeek: [DoneItem] {
        let shown = Set(checklist.map(\.id))
        return doneThisWeek.filter { !shown.contains($0.id) }
    }

    func doneDay(_ id: String) -> String { doneIDs[id] ?? doneThisWeek.first { $0.id == id }?.day ?? day }

    func recordDone() {
        guard fetchedOK else { return }
        if loadedDay != day { loadDay() }
        let known = Set(today.map(\.id) + tasks.map(\.id))
        let gone = Set(doneIDs.keys).union(removedIDs.keys).union(laterIDs).subtracting(known)
        if !gone.isEmpty { write { try db.clearMarks(gone) } }
        let rows = checklist
        let done = Set(rows.filter { $0.done && ($0.item.state?.type ?? "completed") == "completed" }.map(\.id)), shown = Set(rows.map(\.id))
        var log = doneThisWeek.filter { done.contains($0.id) || !shown.contains($0.id) }
        let logged = Set(log.map(\.id))
        log += rows.filter { done.contains($0.id) && !logged.contains($0.id) }
            .map { DoneItem(id: $0.id, title: $0.item.title, url: $0.item.url, source: $0.item.reason, day: doneIDs[$0.id] ?? day) }
        guard log != doneThisWeek else { return }
        doneThisWeek = log
        save(log, weekKey)
    }

    private func save(_ value: some Encodable, _ key: String) { try? db.set(value, key) }

    func toggleDone(_ id: String) {
        let done: String? = doneIDs[id] == nil ? day : nil
        write { try db.mark(id, done: done) }
        recordDone()
    }

    func toggleLater(_ id: String) { write { try db.mark(id, later: !laterIDs.contains(id)) } }

    func remove(_ id: String) { write { try db.mark(id, removed: day) } }

    func restoreRemoved() {
        let none: String? = nil
        write { for id in removedIDs.keys { try db.mark(id, removed: none) } }
    }

    var checklist: [TodoRow] {
        let synced = today.map { TodoRow(item: $0, why: nil, done: $0.closed || doneIDs[$0.id] != nil) }
        let mine = tasks.compactMap { t -> TodoRow? in
            guard let url = URL(string: t.url) else { return nil }
            let item = ActionItem(id: t.id, kind: .followUp, title: t.title, reason: (t.source ?? "").capitalized, url: url, since: .distantPast)
            return TodoRow(item: item, why: t.why, done: doneIDs[t.id] != nil, reply: t.reply)
        }
        let rows = (synced + mine).filter { removedIDs[$0.id] == nil }
        return rows.filter { !laterIDs.contains($0.id) } + rows.filter { laterIDs.contains($0.id) }
    }

    func setState(_ state: WorkflowState, for item: ActionItem) async {
        guard let key = linearKey(), let issue = item.issueID else { return }
        do {
            try await moveIssue(key: key, issueID: issue, stateID: state.id)
            if let i = today.firstIndex(where: { $0.id == item.id }) {
                today[i].state = state
                today[i].started = state.type == "started"
            }
            recordDone()
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

    func refreshAll() async {
        await refresh()
        await synthesize()
    }

    func synthesize() async {
        guard !synthesizing, !demoMode else { return }
        synthesizing = true
        synthesisError = nil
        do {
            synthesis = try await runSynthesis(dir: dir, db: db, candidates: today, tasks: openTasks, me: me ?? "me") { [weak self] in self?.applyTasks($0) }
            synthesizedAt = Date()
            reloadFacts()
            recordDone()
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
                if synthesisDue {
                    await synthesize()
                    if synthesisError == nil { page = .home }
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }
}
