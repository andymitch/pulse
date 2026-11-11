import SwiftUI

struct KnownFact: Identifiable, Equatable {
    struct Source: Equatable { let kind, title: String; let url: URL }
    let id: Int
    let subject, kind, text, observed, status: String
    let subjectTitle, doubt: String?
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
        doubt = d["doubt"] as? String
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
    @State private var askingID: UUID?
    @State private var thought = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Ask about \(project.name)…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(ask)
                    .disabled(asking)
                if asking { ProgressView().controlSize(.small) }
                Button("Ask", action: ask).disabled(asking || blank)
                    .help(localModelReady ? "Answers on this Mac from what Pulse knows, and asks \(agent) when it doesn't know" : "Asks \(agent), which can also look in Linear, Slack and GitHub")
                if !answers.isEmpty {
                    Button("Clear") { answers = []; save() }.disabled(asking).help("Clear the questions and answers")
                }
            }
            ForEach(answers) { a in
                AnswerView(store: store, answer: a, thought: a.id == askingID ? thought : nil, retry: asking ? nil : { run(a.question, replacing: a.id) })
                    .padding(.horizontal, 14)
            }
            FocusHeader(store: store)
            PrioritiesView(store: store)
            if !store.doubts.isEmpty {
                Panel(title: "Needs you") { FactLines(store: store, facts: store.doubts.map(KnownFact.init), reviewing: true) }
            }
        }
        .padding(.top, 6)
        .onAppear { answers = store.db.decode("ask_thread") ?? [] }
    }

    private func save() { try? store.db.set(answers, "ask_thread") }

    private var asking: Bool { askingID != nil }
    private var blank: Bool { question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var agent: String { BriefingAgent.current.name }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return }
        question = ""
        run(q)
    }

    private func run(_ q: String, replacing old: UUID? = nil) {
        guard !asking else { return }
        thought = ""
        let index = old.flatMap { id in answers.firstIndex { $0.id == id } }
        let previous = index.map { $0 > 0 ? answers[$0 - 1] : nil } ?? answers.last
        let facts = (try? factsFor(question: q, in: store.db)) ?? []
        let answer = Answer(question: q, factIDs: localModelReady ? facts.compactMap { $0["id"] as? Int } : [])
        if let index { answers[index] = answer } else { answers.append(answer) }
        askingID = answer.id
        let me = store.me ?? "me"
        Task {
            var a = answer
            if localModelReady {
                a.text = try? await localAnswer(q, facts: facts, previous: previous)
            }
            if a.text == nil || a.text?.contains("doesn't know") == true, !demoMode {
                a.text = nil
                a.factIDs = []
                let id = a.id
                if !facts.isEmpty, let i = answers.firstIndex(where: { $0.id == id }) { answers[i].steps = ["Checking what Pulse knows"] }
                do {
                    a.text = try await agentAnswer(q, me: me, known: facts) { event in
                        guard let i = answers.firstIndex(where: { $0.id == id }) else { return }
                        switch event {
                        case .step(let step):
                            if answers[i].steps?.last != step { answers[i].steps = (answers[i].steps ?? []) + [step] }
                        case .thought(let text):
                            thought = String((thought + text).suffix(400))
                        }
                    }
                } catch {
                    a.error = "\(error)"
                }
                a.steps = answers.first(where: { $0.id == id })?.steps
            }
            if let i = answers.firstIndex(where: { $0.id == a.id }) { answers[i] = a }
            save()
            askingID = nil
        }
    }
}

private struct AnswerView: View {
    @ObservedObject var store: Store
    let answer: Answer
    let thought: String?
    let retry: (() -> Void)?
    @State private var showFacts = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(answer.question).font(.callout.weight(.medium))
            if let text = answer.text {
                linkedText(withoutCitations(text)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else if let error = answer.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(4)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    let steps = answer.steps ?? []
                    ForEach(Array(steps.enumerated().suffix(3)), id: \.offset) { i, step in
                        HStack(spacing: 6) {
                            if i == steps.count - 1 { ProgressView().controlSize(.mini) } else { Image(systemName: "checkmark").font(.caption2) }
                            Text(step).font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    if (answer.steps ?? []).isEmpty { Text("Thinking…").foregroundStyle(.secondary) }
                    if let line = latestThought(thought) {
                        Text(line).font(.caption).italic().foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                    }
                }
            }
            if answer.text != nil || answer.error != nil, let steps = answer.steps, !lookedIn(steps).isEmpty {
                Text(lookedIn(steps)).font(.caption).foregroundStyle(.secondary)
            }
            if answer.text != nil, !answer.factIDs.isEmpty {
                DisclosureGroup(isExpanded: $showFacts) {
                    VStack(alignment: .leading, spacing: 8) {
                        FactLines(store: store, facts: ((try? factsByID(store.db, answer.factIDs)) ?? []).map(KnownFact.init))
                    }
                    .padding(.top, 4)
                } label: {
                    Text("From \(answer.factIDs.count) fact\(answer.factIDs.count == 1 ? "" : "s") Pulse knows").font(.caption).foregroundStyle(.secondary)
                }
            }
            if answer.text != nil || answer.error != nil { actions }
        }
    }

    private var actions: some View {
        HStack(spacing: 14) {
            if let text = answer.text.map(withoutCitations) {
                SpeakButton(text: text)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(markdown(text).characters), forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: { action(copied ? "checkmark" : "doc.on.doc") }
                .help(copied ? "Copied" : "Copy the answer")
                .accessibilityLabel(copied ? "Copied" : "Copy the answer")
            }
            Button { retry?() } label: { action("arrow.clockwise") }
                .disabled(retry == nil)
                .help("Ask again")
                .accessibilityLabel("Ask again")
        }
        .buttonStyle(.plain)
    }

    private func action(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.secondary)
    }
}

func linkLabel(_ text: String, kind: String) -> String {
    kind == "github" ? text.replacingOccurrences(of: "^(PR|pull request|Pull request) ", with: "", options: .regularExpression) : text
}

func linkedText(_ text: String) -> Text {
    let attributed = markdown(text)
    var out = Text("")
    var last: URL?
    for run in attributed.runs {
        var piece = AttributedString(attributed[run.range])
        if let link = run.link, link != last {
            let kind = sourceKind(link, given: "")
            let icon: Image = switch kind {
            case "slack": Image(nsImage: Brand.slack.image(size: 11))
            case "linear": Image(nsImage: Brand.linear.image(size: 11))
            case "github": Image(nsImage: Brand.github.image(size: 11))
            case "mail": Image(systemName: "envelope")
            default: Image(systemName: "link")
            }
            out = out + Text(icon).foregroundColor(Color(nsColor: .linkColor)) + Text("\u{2009}")
            piece = AttributedString(linkLabel(String(piece.characters), kind: kind), attributes: run.attributes)
        }
        last = run.link
        out = out + Text(piece)
    }
    return out
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
    @State private var draft: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text([[fact.subject, fact.subjectTitle].compactMap { $0 }.joined(separator: " "), friendlyDay(fact.observed)].joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                ForEach(fact.replaces, id: \.self) { old in
                    Text(old).strikethrough().foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let draft {
                    TextField("Fact", text: Binding(get: { draft }, set: { self.draft = $0 }), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    HStack(spacing: 12) {
                        Button("Save", action: save).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Cancel") { self.draft = nil }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                } else {
                    Text((fact.replaces.isEmpty ? "" : "→ ") + fact.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if reviewing, let doubt = fact.doubt {
                    Label(doubt, systemImage: "questionmark.circle").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
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
                    Button { store.confirm(fact: fact.id) } label: { Label("Looks right", systemImage: "checkmark") }
                        .help("Confirm it, so Pulse and your agents can rely on it")
                    Button { store.reject(fact: fact.id) } label: { Label("Wrong", systemImage: "xmark") }
                        .help("Stop using it, and bring back what it replaced")
                }
                .controlSize(.small)
                .fixedSize()
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if reviewing { Button("Edit…") { draft = fact.text } }
            Button("Reject as wrong") { store.reject(fact: fact.id) }
            if let s = fact.sources.first {
                Button("Copy link to source") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.url.absoluteString, forType: .string) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func save() {
        guard let draft else { return }
        store.confirm(fact: fact.id, text: draft)
        self.draft = nil
    }
}
