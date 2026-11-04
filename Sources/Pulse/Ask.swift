import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct Answer: Identifiable, Codable {
    var id = UUID()
    let question: String
    var text: String?
    var by = ""
    var factIDs: [Int] = []
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

func agentAnswer(_ question: String, me: String) async throws -> String {
    struct Out: Decodable { let answer: String }
    let out = Settings.dir.appendingPathComponent("ask-answer.json")
    let prompt = """
        Answer \(me)'s question about their work: \(question)

        This is read-only. Never post, react, comment, create, or change anything anywhere.

        Start with what Pulse already knows: if you have Pulse's MCP tools, use search and subject. Then check Linear, Slack or GitHub only if that isn't enough. Newer information wins over older.

        Write one JSON file to \(out.path) with exactly {"answer": string}. The answer is one to four plain sentences that name the tickets, people and dates involved, with Markdown links to the sources you used. If you can't find it, say so.
        """
    return try JSONDecoder().decode(Out.self, from: try await runAgent(prompt, output: out, name: "ask")).answer
}
