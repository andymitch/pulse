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
            (s["url"] as? String).flatMap(URL.init).map { Source(kind: sourceKind($0, given: s["kind"] as? String ?? ""), title: sourceTitle(s["title"] as? String ?? "", url: $0), url: $0) }
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
    @State private var question = ""
    @State private var answers: [Answer] = []
    @State private var asking = false
    @AppStorage("askOnThisMac") private var onThisMac = true
    @AppStorage("askFallback") private var fallback = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Ask about your work, like when Requests v1 launches", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { ask(question, local: local) }
                    .disabled(asking)
                if asking { ProgressView().controlSize(.small) }
                if localModelReady {
                    SplitButton(help: local ? "Answer on this Mac from what Pulse knows" : "Ask \(agent), which can also look in Linear, Slack and GitHub", width: nil) {
                        ask(question, local: local)
                    } title: {
                        Text(local ? "Ask" : "Ask \(agent)")
                    } items: {
                        Button("Ask on this Mac") { onThisMac = true; ask(question, local: true) }
                        Button("Ask \(agent)") { onThisMac = false; ask(question, local: false) }.disabled(demoMode)
                        Divider()
                        Toggle("Ask \(agent) when this Mac doesn't know", isOn: $fallback)
                    }
                    .disabled(asking || blank)
                } else {
                    Button("Ask \(agent)") { ask(question, local: false) }.disabled(asking || blank || demoMode)
                        .help("Ask \(agent), which can also look in Linear, Slack and GitHub")
                }
                if !answers.isEmpty {
                    Button("Clear") { answers = []; save() }.disabled(asking).help("Clear the questions and answers")
                }
            }
            ForEach(answers) { a in
                AnswerView(store: store, answer: a, askAgent: asking || demoMode ? nil : { ask(a.question, local: false) })
                    .padding(.horizontal, 14)
            }
            FocusHeader(store: store)
            PrioritiesView(store: store)
            if !store.pendingFacts.isEmpty {
                Panel(title: "Agents noted") {
                    ForEach(store.pendingFacts) { fact in
                        PendingFactRow(store: store, fact: fact)
                        if fact.id != store.pendingFacts.last?.id { Divider() }
                    }
                }
            }
            let changed = store.changed.map(KnownFact.init)
            if !changed.isEmpty {
                Panel(title: "Pulse changed its mind", accessory: {
                    Button("Mark all reviewed") { store.markReviewed() }.buttonStyle(.link).font(.caption)
                }) {
                    FactLines(store: store, facts: changed, reviewing: true)
                }
            }
            if changed.isEmpty && store.pendingFacts.isEmpty {
                Text("Nothing to resolve. Facts that agents note, or that replace something Pulse knew, show up here.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
            }
        }
        .padding(.top, 6)
        .onAppear { answers = store.db.decode("ask_thread") ?? [] }
    }

    private func save() { try? store.db.set(answers, "ask_thread") }

    private var blank: Bool { question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var local: Bool { localModelReady && (onThisMac || demoMode) }
    private var agent: String { BriefingAgent.current.name }

    private func ask(_ text: String, local: Bool) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return }
        if text == question { question = "" }
        asking = true
        let previous = answers.last
        let facts = (try? factsFor(question: q, in: store.db)) ?? []
        answers.append(Answer(question: q, by: local ? "On this Mac" : BriefingAgent.current.name, factIDs: local ? facts.compactMap { $0["id"] as? Int } : []))
        let me = store.me ?? "me"
        Task {
            var a = answers[answers.count - 1]
            do {
                a.text = local ? try await localAnswer(q, facts: facts, previous: previous) : try await agentAnswer(q, me: me)
            } catch {
                a.error = "\(error)"
            }
            if let i = answers.firstIndex(where: { $0.id == a.id }) { answers[i] = a }
            save()
            asking = false
            if local, fallback, !demoMode, a.error != nil || a.text?.contains("doesn't know") == true { ask(q, local: false) }
        }
    }
}

private struct AnswerView: View {
    @ObservedObject var store: Store
    let answer: Answer
    let askAgent: (() -> Void)?
    @State private var showFacts = false

    private var stuck: Bool {
        answer.by == "On this Mac" && (answer.error != nil || answer.text?.contains("doesn't know") == true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(answer.question).font(.callout.weight(.medium))
            if let text = answer.text {
                HStack(alignment: .firstTextBaseline) {
                    Text(markdown(answer.by == "On this Mac" ? withoutCitations(text) : text)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if stuck, let askAgent { Button("Ask \(BriefingAgent.current.name)", action: askAgent).controlSize(.small).help("Ask the same question of \(BriefingAgent.current.name), which can also look in Linear, Slack and GitHub") }
                }
            } else if let error = answer.error {
                HStack(alignment: .firstTextBaseline) {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(4)
                    Spacer(minLength: 8)
                    if stuck, let askAgent { Button("Ask \(BriefingAgent.current.name)", action: askAgent).controlSize(.small) }
                }
            } else {
                Text("Thinking…").foregroundStyle(.secondary)
            }
            if !answer.factIDs.isEmpty {
                DisclosureGroup(isExpanded: $showFacts) {
                    VStack(alignment: .leading, spacing: 8) {
                        FactLines(store: store, facts: ((try? factsByID(store.db, answer.factIDs)) ?? []).map(KnownFact.init))
                    }
                    .padding(.top, 4)
                } label: {
                    Text("\(answer.by) · from \(answer.factIDs.count) fact\(answer.factIDs.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                }
            } else if answer.text != nil {
                Text(answer.by).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct FactLines: View {
    @ObservedObject var store: Store
    let facts: [KnownFact]
    var reviewing = false

    var body: some View {
        ForEach(Array(facts.enumerated()), id: \.element.id) { i, fact in
            FactLine(store: store, fact: fact, reviewing: reviewing)
            if i < facts.count - 1 { Divider() }
        }
    }
}

private func destination(_ s: KnownFact.Source) -> String {
    switch s.kind {
    case "slack": FileManager.default.fileExists(atPath: App.slack.url.path) ? "Opens in Slack" : "Opens Slack in your browser"
    case "linear": FileManager.default.fileExists(atPath: App.linear.url.path) ? "Opens in Linear" : "Opens Linear in your browser"
    case "github": "Opens on GitHub"
    case "meeting": "Opens the meeting's notes and transcript"
    case "session": "Opens the agent session's digest"
    case "mail": "Opens in Mail"
    default: "Opens \(s.url.host ?? "the link")"
    }
}

private struct FactLine: View {
    @ObservedObject var store: Store
    let fact: KnownFact
    let reviewing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text([[fact.subject, fact.subjectTitle].compactMap { $0 }.joined(separator: " "), friendlyDay(fact.observed)].joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                ForEach(fact.replaces, id: \.self) { old in
                    Text(old).strikethrough().foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text((fact.replaces.isEmpty ? "" : "→ ") + fact.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                ForEach(Array(fact.sources.prefix(3).enumerated()), id: \.offset) { _, s in
                    Button { openSource(s.url, kind: s.kind) } label: {
                        HStack(spacing: 5) {
                            SourceIcon(kind: s.kind, url: s.url, size: 10)
                            Text(s.title).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("\(destination(s)): \(s.url.absoluteString)")
                    .accessibilityLabel("Source: \(s.title). \(destination(s))")
                }
                if fact.sources.count > 3 { Text("and \(fact.sources.count - 3) more").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 4)
            if reviewing {
                HStack(spacing: 6) {
                    Button { store.reviewed(fact: fact.id) } label: { Label("Looks right", systemImage: "checkmark") }
                        .help("Keep it and take it off this list")
                    Button { store.reject(fact: fact.id) } label: { Label("Wrong", systemImage: "xmark") }
                        .help("Stop using it, and bring back what it replaced")
                }
                .controlSize(.small)
                .fixedSize()
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reject as wrong") { store.reject(fact: fact.id) }
            if let s = fact.sources.first {
                Button("Copy link to source") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.url.absoluteString, forType: .string) }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
