import SwiftUI

struct KnownFact: Identifiable, Equatable {
    struct Source: Equatable { let title: String; let url: URL }
    let id: Int
    let subject, kind, text, observed, status: String
    let replaced: Bool
    let sources: [Source]

    init(_ d: [String: Any]) {
        id = d["id"] as? Int ?? 0
        subject = (d["subject"] as? [String: Any])?["name"] as? String ?? ""
        kind = d["kind"] as? String ?? ""
        text = d["text"] as? String ?? ""
        observed = d["observed"] as? String ?? ""
        status = d["status"] as? String ?? ""
        replaced = d["supersededBy"] != nil
        sources = ((d["sources"] as? [[String: Any]]) ?? []).compactMap { s in
            (s["url"] as? String).flatMap(URL.init).map { Source(title: s["title"] as? String ?? $0.absoluteString, url: $0) }
        }
    }
}

struct KnowledgeView: View {
    @ObservedObject var store: Store
    @State private var query = ""
    @State private var subject: String?
    @State private var subjects: [[String: Any]] = []
    @State private var facts: [KnownFact] = []
    @State private var history: [KnownFact] = []
    @State private var showHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let subject {
                HStack {
                    Button { self.subject = nil } label: { Label("All subjects", systemImage: "chevron.left") }.buttonStyle(.link)
                    Spacer()
                }
                Text(subject).font(.title3.weight(.semibold))
                Panel(title: "Now · \(facts.count)") { factList(facts, editable: true) }
                if !history.isEmpty {
                    DisclosureGroup("Replaced · \(history.count)", isExpanded: $showHistory) {
                        VStack(alignment: .leading, spacing: 8) { factList(history, editable: false) }.padding(.top, 6)
                    }
                    .padding(.horizontal, 14)
                    .foregroundStyle(.secondary)
                }
            } else {
                TextField("Search what Pulse knows", text: $query).textFieldStyle(.roundedBorder)
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Panel(title: "Subjects · \(subjects.count)") {
                        if subjects.isEmpty { Text("Nothing learned yet. Pulse learns from each briefing.").foregroundStyle(.secondary) }
                        ForEach(Array(subjects.enumerated()), id: \.offset) { i, s in
                            let name = s["name"] as? String ?? ""
                            Button { subject = name } label: {
                                HStack {
                                    Text(name).lineLimit(1)
                                    Spacer()
                                    Text("\(s["kind"] as? String ?? "") · \(s["facts"] as? Int ?? 0) · \(s["latest"] as? String ?? "")").font(.caption).foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(name), \(s["kind"] as? String ?? ""), \(s["facts"] as? Int ?? 0) fact\(s["facts"] as? Int == 1 ? "" : "s")")
                            if i < subjects.count - 1 { Divider() }
                        }
                    }
                } else {
                    Panel(title: "Facts · \(facts.count)") {
                        if facts.isEmpty { Text("No facts match.").foregroundStyle(.secondary) }
                        factList(facts, editable: true, showSubject: true)
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: query) { _, _ in reload() }
        .onChange(of: subject) { _, _ in showHistory = false; reload() }
        .onChange(of: store.pendingFacts) { _, _ in reload() }
        .onChange(of: store.synthesizedAt) { _, _ in reload() }
    }

    @ViewBuilder private func factList(_ list: [KnownFact], editable: Bool, showSubject: Bool = false) -> some View {
        ForEach(list) { fact in
            KnownFactRow(fact: fact, editable: editable, showSubject: showSubject, open: { subject = fact.subject }) { text in
                do {
                    if let text { try confirmFact(store.db, id: fact.id, text: text) } else { try rejectFact(store.db, id: fact.id) }
                } catch {
                    store.lastError = "\(error)"
                }
                store.pendingFacts = (try? unconfirmedFacts(store.db)) ?? []
                reload()
            }
            if fact.id != list.last?.id { Divider() }
        }
    }

    private func reload() {
        let db = store.db
        if let subject {
            let all = ((try? subjectFacts(db, name: subject)) as? [String: Any]).map { s in
                (((s["current"] as? [[String: Any]]) ?? []).map(KnownFact.init), ((s["history"] as? [[String: Any]]) ?? []).map(KnownFact.init))
            }
            (facts, history) = all ?? ([], [])
        } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            facts = ((try? searchFacts(db, query: query, limit: 100)) ?? []).map(KnownFact.init)
        } else {
            subjects = ((try? subjectFacts(db, name: nil)) as? [[String: Any]]) ?? []
        }
    }
}

private struct KnownFactRow: View {
    let fact: KnownFact
    let editable, showSubject: Bool
    let open: () -> Void
    let change: (String?) -> Void
    @State private var draft: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let draft {
                TextField("Fact", text: Binding(get: { draft }, set: { self.draft = $0 }), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
            } else {
                Text(fact.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).strikethrough(fact.replaced)
            }
            Text(([showSubject ? fact.subject : nil, fact.kind, fact.observed, fact.status == "confirmed" ? nil : fact.status] as [String?]).compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if showSubject { Button("Subject", action: open) }
                ForEach(Array(fact.sources.prefix(3).enumerated()), id: \.offset) { _, s in
                    Button { Pulse.open(s.url) } label: {
                        Text(s.title.hasPrefix("http") ? s.url.host ?? "Link" : s.title).lineLimit(1).truncationMode(.tail)
                    }
                    .help(s.url.absoluteString)
                }
                if editable {
                    Spacer()
                    if draft == nil {
                        Button("Edit") { draft = fact.text }
                        Button("Reject") { change(nil) }.help("Wrong: stop using it, and bring back what it replaced")
                    } else {
                        Button("Save", action: save).disabled(draft?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
                        Button("Cancel") { draft = nil }
                    }
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    private func save() {
        guard let draft else { return }
        change(draft)
        self.draft = nil
    }
}
