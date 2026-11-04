import SwiftUI

struct KnownFact: Identifiable, Equatable {
    struct Source: Equatable { let kind, title: String; let url: URL }
    let id: Int
    let subject, kind, text, observed, status: String
    let replaced: Bool
    let sources: [Source]

    init(_ d: [String: Any]) {
        id = d["id"] as? Int ?? 0
        subject = (d["subject"] as? [String: Any])?["name"] as? String ?? ""
        kind = d["kind"] as? String ?? ""
        observed = d["observed"] as? String ?? ""
        text = withoutOwnDate(d["text"] as? String ?? "", observed)
        status = d["status"] as? String ?? ""
        replaced = d["supersededBy"] != nil
        sources = ((d["sources"] as? [[String: Any]]) ?? []).compactMap { s in
            (s["url"] as? String).flatMap(URL.init).map { Source(kind: s["kind"] as? String ?? "", title: s["title"] as? String ?? $0.absoluteString, url: $0) }
        }
    }
}

func withoutOwnDate(_ text: String, _ day: String) -> String {
    let d = NSRegularExpression.escapedPattern(for: day)
    var t = text
    if !day.isEmpty {
        for pattern in ["^(On|As of|Since|By) \(d),? ", " \\((decided |as of |on )?\(d)\\)", ",? (on|as of) \(d)(?!:)"] {
            t = t.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        if t != text, let first = t.first { t = first.uppercased() + t.dropFirst() }
    }
    let iso = try! NSRegularExpression(pattern: "\\b(\\d{4})-(\\d{2})-(\\d{2})\\b")
    for m in iso.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
        guard let r = Range(m.range, in: t), let date = try? Date(String(t[r]), strategy: localDay) else { continue }
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date())
        t.replaceSubrange(r, with: date.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year()))
    }
    return t
}

func friendlyDay(_ day: String, now: Date = Date()) -> String {
    guard let date = try? Date(day, strategy: localDay) else { return day }
    let cal = Calendar.current
    if cal.isDate(date, inSameDayAs: now) { return "Today" }
    if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return "Yesterday" }
    if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day, (2..<7).contains(days) {
        return date.formatted(.dateTime.weekday(.wide))
    }
    return date.formatted(.dateTime.month(.abbreviated).day())
}

private let sections: [(kind: String, title: String)] = [("project", "Projects"), ("ticket", "Tickets"), ("person", "People"), ("topic", "Topics")]
private let groups: [(kind: String, title: String)] = [
    ("status", "Where it stands"), ("decision", "Decided"), ("blocker", "Blocked on"), ("owner", "Who owns what"),
    ("commitment", "Promised"), ("question", "Open questions"), ("preference", "Preferences"),
]

private struct SubjectEntry: Identifiable {
    let kind, name, latest: String
    let title: String?
    var id: String { kind + name }

    init(_ d: [String: Any]) {
        kind = d["kind"] as? String ?? ""
        name = d["name"] as? String ?? ""
        latest = d["latest"] as? String ?? ""
        title = kind == "ticket" ? (d["aliases"] as? [String])?.first : nil
    }
}

struct KnowledgeView: View {
    @ObservedObject var store: Store
    @State private var query = ""
    @State private var subject: SubjectEntry?
    @State private var subjects: [SubjectEntry] = []
    @State private var facts: [KnownFact] = []
    @State private var history: [KnownFact] = []
    @State private var showHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let subject {
                Button { self.subject = nil } label: { Label("All subjects", systemImage: "chevron.left") }.buttonStyle(.link)
                HStack(alignment: .firstTextBaseline) {
                    Text(subject.title ?? subject.name).font(.title3.weight(.semibold))
                    if subject.title != nil { Text(subject.name).foregroundStyle(.secondary) }
                }
                ForEach(groups, id: \.kind) { group in
                    let list = facts.filter { $0.kind == group.kind }
                    if !list.isEmpty { Panel(title: group.title) { factList(list) } }
                }
                if !history.isEmpty {
                    DisclosureGroup("Replaced · \(history.count)", isExpanded: $showHistory) {
                        VStack(alignment: .leading, spacing: 8) { factList(history) }.padding(.top, 6)
                    }
                    .padding(.horizontal, 14)
                    .foregroundStyle(.secondary)
                }
            } else {
                TextField("Search what Pulse knows", text: $query).textFieldStyle(.roundedBorder)
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    if subjects.isEmpty { Text("Nothing learned yet. Pulse learns from each briefing.").foregroundStyle(.secondary) }
                    ForEach(sections, id: \.kind) { section in
                        let list = subjects.filter { $0.kind == section.kind }
                        if !list.isEmpty {
                            Panel(title: section.title) {
                                ForEach(list) { s in
                                    subjectRow(s)
                                    if s.id != list.last?.id { Divider() }
                                }
                            }
                        }
                    }
                } else {
                    Panel(title: "Results") {
                        if facts.isEmpty { Text("Nothing matches.").foregroundStyle(.secondary) }
                        factList(facts, showSubject: true)
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: query) { _, _ in reload() }
        .onChange(of: subject?.id) { _, _ in showHistory = false; reload() }
        .onChange(of: store.pendingFacts) { _, _ in reload() }
        .onChange(of: store.synthesizedAt) { _, _ in reload() }
    }

    private func subjectRow(_ s: SubjectEntry) -> some View {
        Button { subject = s } label: {
            HStack(spacing: 6) {
                Text(s.title ?? s.name).lineLimit(1)
                if s.title != nil { Text(s.name).foregroundStyle(.secondary).fixedSize() }
                Spacer()
                Text(friendlyDay(s.latest)).font(.caption).foregroundStyle(.secondary).fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([s.title, s.name, "last changed \(friendlyDay(s.latest))"].compactMap { $0 }.joined(separator: ", "))
    }

    @ViewBuilder private func factList(_ list: [KnownFact], showSubject: Bool = false) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { i, fact in
            let newDay = i == 0 || list[i - 1].observed != fact.observed
            if newDay || showSubject {
                Text([showSubject ? fact.subject : nil, newDay || showSubject ? friendlyDay(fact.observed) : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.top, i == 0 ? 0 : 4)
            }
            KnownFactRow(fact: fact, open: showSubject ? { subject = subjects.first { $0.name == fact.subject } } : nil) { text in
                do {
                    if let text { try confirmFact(store.db, id: fact.id, text: text) } else { try rejectFact(store.db, id: fact.id) }
                } catch {
                    store.lastError = "\(error)"
                }
                store.pendingFacts = (try? unconfirmedFacts(store.db)) ?? []
                reload()
            }
        }
    }

    private func reload() {
        let db = store.db
        subjects = (((try? subjectFacts(db, name: nil)) as? [[String: Any]]) ?? []).map(SubjectEntry.init)
        if let subject {
            let all = ((try? subjectFacts(db, name: subject.name)) as? [String: Any]).map { s in
                (((s["current"] as? [[String: Any]]) ?? []).map(KnownFact.init), ((s["history"] as? [[String: Any]]) ?? []).map(KnownFact.init))
            }
            (facts, history) = all ?? ([], [])
        } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            facts = ((try? searchFacts(db, query: query, limit: 100)) ?? []).map(KnownFact.init)
        }
    }
}

private struct KnownFactRow: View {
    let fact: KnownFact
    let open: (() -> Void)?
    let change: (String?) -> Void
    @State private var draft: String?

    var body: some View {
        if let draft {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Fact", text: Binding(get: { draft }, set: { self.draft = $0 }), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                HStack(spacing: 12) {
                    Button("Save", action: save).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { self.draft = nil }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                (Text(fact.text).strikethrough(fact.replaced) + Text(fact.status == "unconfirmed" ? "  unconfirmed" : "").font(.caption).foregroundColor(.orange))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                HStack(spacing: 5) {
                    ForEach(Array(fact.sources.prefix(4).enumerated()), id: \.offset) { _, s in
                        Button { Pulse.open(s.url) } label: { SourceIcon(kind: s.kind, size: 11) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help(s.title)
                            .accessibilityLabel("Source: \(s.title)")
                    }
                }
                .fixedSize()
            }
            .contentShape(Rectangle())
            .contextMenu {
                if let open { Button("Open \(fact.subject)", action: open) }
                if !fact.replaced {
                    Button("Edit…") { draft = fact.text }
                    Button("Reject as wrong") { change(nil) }
                }
                if let s = fact.sources.first { Button("Copy link to source") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.url.absoluteString, forType: .string) } }
            }
            .accessibilityElement(children: .contain)
            .accessibilityActions {
                if !fact.replaced {
                    Button("Edit") { draft = fact.text }
                    Button("Reject as wrong") { change(nil) }
                }
            }
        }
    }

    private func save() {
        guard let draft else { return }
        change(draft)
        self.draft = nil
    }
}
