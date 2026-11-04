import SwiftUI

struct KnownFact: Identifiable, Equatable {
    struct Source: Equatable { let kind, title: String; let url: URL }
    let id: Int
    let subject, kind, text, observed, status: String
    let subjectTitle: String?
    let replaced: Bool
    let replaces: [String]
    let sources: [Source]

    init(_ d: [String: Any]) {
        id = d["id"] as? Int ?? 0
        subject = (d["subject"] as? [String: Any])?["name"] as? String ?? ""
        subjectTitle = (d["subject"] as? [String: Any])?["title"] as? String
        kind = d["kind"] as? String ?? ""
        observed = d["observed"] as? String ?? ""
        text = withoutOwnDate(d["text"] as? String ?? "", observed)
        status = d["status"] as? String ?? ""
        replaced = d["supersededBy"] != nil
        let day = observed
        replaces = ((d["replaces"] as? [[String: Any]]) ?? []).compactMap { r in (r["text"] as? String).map { withoutOwnDate($0, r["observed"] as? String ?? day) } }
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

struct KnowledgeView: View {
    @ObservedObject var store: Store
    @State private var query = ""
    @State private var results: [KnownFact] = []

    var body: some View {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(alignment: .leading, spacing: 12) {
            TextField("Ask what Pulse knows, like KLE-1209 or auto-close", text: $query).textFieldStyle(.roundedBorder)
            if searching {
                Panel(title: "What Pulse knows") {
                    if results.isEmpty { Text("Nothing about that yet.").foregroundStyle(.secondary) }
                    FactLines(store: store, facts: results)
                }
            } else {
                if !store.pendingFacts.isEmpty {
                    Panel(title: "Agents noted · confirm or reject") {
                        ForEach(store.pendingFacts) { fact in
                            PendingFactRow(store: store, fact: fact)
                            if fact.id != store.pendingFacts.last?.id { Divider() }
                        }
                    }
                }
                let changed = store.changed.map(KnownFact.init)
                Panel(title: "Since you last looked", accessory: {
                    if !changed.isEmpty { Button("Mark all reviewed") { store.markReviewed() }.buttonStyle(.link).font(.caption) }
                }) {
                    if changed.isEmpty {
                        Text("You're caught up. New and changed facts show up here after each briefing.").foregroundStyle(.secondary)
                    }
                    FactLines(store: store, facts: changed)
                }
            }
        }
        .onAppear(perform: search)
        .onChange(of: query) { _, _ in search() }
        .onChange(of: store.factsVersion) { _, _ in search() }
    }

    private func search() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return results = [] }
        results = ((try? searchFacts(store.db, query: query, limit: 50)) ?? []).map(KnownFact.init)
    }
}

struct FactLines: View {
    @ObservedObject var store: Store
    let facts: [KnownFact]
    var showSubject = true

    var body: some View {
        ForEach(Array(facts.enumerated()), id: \.element.id) { i, fact in
            FactLine(store: store, fact: fact, showSubject: showSubject)
            if i < facts.count - 1 { Divider() }
        }
    }
}

private struct FactLine: View {
    @ObservedObject var store: Store
    let fact: KnownFact
    let showSubject: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(([showSubject ? [fact.subject, fact.subjectTitle].compactMap { $0 }.joined(separator: " ") : nil, friendlyDay(fact.observed)] as [String?]).compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                ForEach(fact.replaces, id: \.self) { old in
                    Text(old).strikethrough().foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text((fact.replaces.isEmpty ? "" : "→ ") + fact.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Spacer(minLength: 4)
            HStack(spacing: 5) {
                ForEach(Array(fact.sources.prefix(4).enumerated()), id: \.offset) { _, s in
                    Button { open(s.url) } label: { SourceIcon(kind: s.kind, size: 11) }
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
            Button("Reject as wrong") { store.reject(fact: fact.id) }
            if let s = fact.sources.first {
                Button("Copy link to source") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.url.absoluteString, forType: .string) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Reject as wrong") { store.reject(fact: fact.id) }
    }
}

struct KnownAbout: View {
    @ObservedObject var store: Store
    let names: [String]
    @State private var open = false
    @State private var facts: [KnownFact] = []

    var body: some View {
        if !names.isEmpty {
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 8) { FactLines(store: store, facts: facts, showSubject: names.count > 1) }
                    .padding(.top, 4)
            } label: {
                Text("What Pulse knows").font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: open) { _, _ in load() }
            .onChange(of: store.factsVersion) { _, _ in load() }
        }
    }

    private func load() {
        guard open else { return }
        facts = names.flatMap { name in
            (((try? subjectFacts(store.db, name: name)) as? [String: Any])?["current"] as? [[String: Any]] ?? []).map(KnownFact.init)
        }
    }
}
