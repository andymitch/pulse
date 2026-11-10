import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct Answer: Identifiable, Codable {
    var id = UUID()
    let question: String
    var text: String?
    var factIDs: [Int] = []
    var steps: [String]?
    var error: String?
}

var localModelReady: Bool {
    #if canImport(FoundationModels)
    if #available(macOS 26, *), case .available = SystemLanguageModel.default.availability { return true }
    #endif
    return false
}

func askPrompt(_ question: String, facts: [[String: Any]], previous: Answer?) -> String {
    let lines = facts.map { f in
        let subject = (f["subject"] as? [String: Any])?["name"] as? String ?? ""
        return "- \(f["observed"] as? String ?? "") · \(subject): \(String((f["text"] as? String ?? "").prefix(260)))"
    }
    let before = previous.flatMap { p in p.text.map { "Earlier the user asked \"\(p.question)\" and you answered \"\($0)\".\n\n" } } ?? ""
    return before + "Facts:\n" + (lines.isEmpty ? "(none)" : lines.joined(separator: "\n")) + "\n\nQuestion: \(question)"
}

let askInstructions = """
    You answer questions about the user's work using only the facts given with each question. Newer facts win over older ones. \
    Keep the facts' own wording for anything negative or exact, such as "no", "not", "never", names, numbers and dates. \
    If the facts don't answer the question, say "Pulse doesn't know that yet." and nothing more. \
    Answer in one to three short sentences.
    """

func withoutCitations(_ text: String) -> String {
    text.replacingOccurrences(of: "\\s*\\[\\d+(, ?\\d+)*\\]", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
}

func localAnswer(_ question: String, facts: [[String: Any]], previous: Answer?) async throws -> String? {
    #if canImport(FoundationModels)
    if #available(macOS 26, *), case .available = SystemLanguageModel.default.availability {
        let session = LanguageModelSession(instructions: askInstructions)
        return withoutCitations(try await session.respond(to: askPrompt(question, facts: facts, previous: previous)).content)
    }
    #endif
    return nil
}

func agentAnswer(_ question: String, me: String, known: [[String: Any]] = [], onEvent: @escaping @MainActor (AgentEvent) -> Void = { _ in }) async throws -> String {
    struct Out: Decodable { let answer: String }
    let out = project.dir.appendingPathComponent("ask-answer.json")
    let file = project.dir.appendingPathComponent("ask-prompt.md")
    let prompt = """
        Answer \(me)'s question about their work: \(question)

        This is read-only. Never post, react, comment, create, or change anything anywhere.

        \(known.isEmpty ? "Pulse has no facts that match the question." : "What Pulse already knows that may help, newest first, each with its sources:\n" + known.map { f in "- \(f["observed"] as? String ?? "") \((f["subject"] as? [String: Any])?["name"] as? String ?? ""): \(f["text"] as? String ?? "") " + (((f["sources"] as? [[String: Any]]) ?? []).compactMap { $0["url"] as? String }.map { "<\($0)>" }.joined(separator: " ")) }.joined(separator: "\n"))

        Answer from that when it's enough. Otherwise look further: Pulse's MCP search and subject tools if you have them, then Linear, Slack or GitHub. Newer information wins over older.

        Write one JSON file to \(out.path) with exactly {"answer": string}. The answer is one to four plain sentences that name the tickets, people and dates involved, with Markdown links to the sources you used. Put each link on the words it backs up, where they appear in the sentence: a ticket ID like [KLE-123](…), a PR number like [#1490](…), or the few words a message or doc supports, like [Chad Schwab reported](…) or [done 31 Aug](…). Never add a separate link such as "(Slack)" or "source" at the end. If you can't find it, say so.
        """
    try? FileManager.default.removeItem(at: out)
    try prompt.write(to: file, atomically: true, encoding: .utf8)
    let command = "cd \"$HOME\" && " + streaming(settings.briefingCommand.replacingOccurrences(of: "{prompt}", with: quoted(file.path)))
    try await Task.detached {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        for try await line in pipe.fileHandleForReading.bytes.lines {
            for event in agentEvents(line) { await onEvent(event) }
        }
        p.waitUntilExit()
    }.value
    guard let data = try? Data(contentsOf: out) else { throw SyncError(description: "\(BriefingAgent.current.name) didn't answer.") }
    return try JSONDecoder().decode(Out.self, from: data).answer
}

enum AgentEvent: Equatable {
    case step(String)
    case thought(String)
}

private let services = ["pulse": "Pulse", "linear": "Linear", "slack": "Slack", "github": "GitHub", "cloudwatch": "CloudWatch", "playwright": "the browser"]

private func describe(tool name: String, args: [String: Any]) -> [AgentEvent] {
    let text = (args["code"] as? String) ?? (args["command"] as? String) ?? ""
    var calls: [(server: String, query: String?)] = []
    if name.hasPrefix("mcp__") {
        calls.append((String(name.split(separator: "_", omittingEmptySubsequences: true).first(where: { $0 != "mcp" }) ?? ""), args["query"] as? String))
    } else if name == "codemode" {
        let query = (try? Regex<(Substring, Substring)>(#"query:\s*["'`]([^"'`\n]{1,60})["'`]"#)).flatMap { text.firstMatch(of: $0) }.map { String($0.1) }
        let servers = (try? Regex<(Substring, Substring)>(#"mcp__([a-z0-9]+)__"#)).map { text.matches(of: $0).map { String($0.1) } } ?? []
        for server in servers where !calls.contains(where: { $0.server == server }) { calls.append((server, query)) }
    } else if name.lowercased() == "bash", text.contains("gh ") {
        calls.append(("github", nil))
    }
    return calls.map { call in
        let service = services[call.server] ?? call.server.capitalized
        if call.server == "pulse" { return .step("Checking what Pulse knows") }
        return .step("Looking in \(service)" + (call.query.map { " for \"\($0)\"" } ?? ""))
    }
}

func agentEvents(_ line: String) -> [AgentEvent] {
    guard let d = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return [] }
    switch d["type"] as? String {
    case "tool_execution_start":
        return describe(tool: d["toolName"] as? String ?? "", args: d["args"] as? [String: Any] ?? [:])
    case "message_update":
        let e = d["assistantMessageEvent"] as? [String: Any]
        return e?["type"] as? String == "thinking_delta" ? [.thought(e?["delta"] as? String ?? "")] : []
    case "assistant":
        return ((d["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []).flatMap { c -> [AgentEvent] in
            switch c["type"] as? String {
            case "tool_use": describe(tool: c["name"] as? String ?? "", args: c["input"] as? [String: Any] ?? [:])
            case "thinking": [.thought((c["thinking"] as? String ?? "") + " ")]
            default: []
            }
        }
    default:
        return []
    }
}

func streaming(_ command: String) -> String {
    let c = command.trimmingCharacters(in: .whitespaces)
    if c.hasPrefix("pi "), !c.contains("--mode") { return "pi --mode json " + c.dropFirst(3) }
    if c.hasPrefix("claude "), !c.contains("--output-format") { return "claude --output-format stream-json --verbose " + c.dropFirst(7) }
    return c
}

func lookedIn(_ steps: [String]) -> String {
    var names: [String] = []
    for s in steps {
        let name = s.hasPrefix("Checking what Pulse knows") ? "Pulse" : s.hasPrefix("Looking in ") ? String(s.dropFirst(11).split(separator: " for ").first ?? "") : nil
        if let name, !names.contains(name) { names.append(name) }
    }
    guard let last = names.last else { return "" }
    return "Looked in " + (names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last)
}

func latestThought(_ text: String?) -> String? {
    guard let text, !text.isEmpty else { return nil }
    let sentences = text.split(whereSeparator: { ".!?\n".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 8 }
    return sentences.last
}
