import Foundation

struct SlackChannel: Codable, Hashable {
    let id, name: String
}

enum MCPService: String {
    case slack, linear

    var url: String { self == .slack ? "https://mcp.slack.com/mcp" : "https://mcp.linear.app/mcp" }
    var host: String { URL(string: url)!.host! }
    var name: String { rawValue.capitalized }
}

enum BriefingAgent {
    case pi, claude

    static var current: BriefingAgent {
        settings.briefingCommand.trimmingCharacters(in: .whitespaces).hasPrefix("claude") ? .claude : .pi
    }

    var name: String { self == .pi ? "pi" : "Claude Code" }

    var installed: Bool { (try? shell("command -v \(self == .pi ? "pi" : "claude")")) != nil }

    func connected(_ service: MCPService) -> Bool {
        switch self {
        case .pi:
            struct List: Decodable { struct Server: Decodable { let transport: String; let state: String }; let servers: [Server] }
            let out = (try? shell("pi mcp list --json 2>/dev/null || true")) ?? ""
            let list = try? JSONDecoder().decode(List.self, from: Data(out.utf8))
            return list?.servers.contains { $0.transport.contains(service.host) && $0.state == "connected" } ?? false
        case .claude:
            let out = (try? shell("claude mcp list 2>/dev/null || true")) ?? ""
            return out.split(separator: "\n").contains { $0.contains(service.host) && $0.contains("Connected") }
        }
    }

    func connect(_ service: MCPService) throws {
        switch self {
        case .pi:
            let configured = ((try? shell("pi mcp list --json 2>/dev/null || true")) ?? "").contains(service.host)
            if !configured { try shell("pi mcp add \(service.rawValue) --url \(service.url)") }
            try shell("pi mcp login \(service.rawValue) --timeout 300")
        case .claude:
            let listed = ((try? shell("claude mcp list 2>/dev/null || true")) ?? "").contains(service.host)
            if !listed { try shell("claude mcp add --transport http --scope user \(service.rawValue) \(service.url)") }
            try openCommandInTerminal("claude '/mcp'")
        }
    }
}

func runAgent(_ prompt: String, output: URL, name: String) async throws -> Data {
    let file = Settings.dir.appendingPathComponent("\(name)-prompt.md")
    try? FileManager.default.removeItem(at: output)
    try prompt.write(to: file, atomically: true, encoding: .utf8)
    let command = "cd \"$HOME\" && " + settings.briefingCommand.replacingOccurrences(of: "{prompt}", with: quoted(file.path))
    let log = await Task.detached { () -> String in
        (try? shell(command)).map { String($0.suffix(2000)) } ?? "the agent exited with an error"
    }.value
    guard let data = try? Data(contentsOf: output) else {
        throw SyncError(description: "\(BriefingAgent.current.name) did not write \(output.lastPathComponent). Last output:\n\(log)")
    }
    return data
}

private let channelsFile = Settings.dir.appendingPathComponent("slack-channels.json")

func cachedSlackChannels() -> [SlackChannel] {
    (try? Data(contentsOf: channelsFile)).flatMap { try? JSONDecoder().decode([SlackChannel].self, from: $0) } ?? []
}

var slackChannelsStale: Bool {
    let modified = (try? channelsFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    return Date().timeIntervalSince(modified) > 86400
}

func fetchSlackChannels() async throws -> [SlackChannel] {
    let out = channelsFile.appendingPathExtension("new")
    let prompt = """
    Using your Slack tools (in pi, call them through codemode), list every channel I am a member of: public and private, not archived, and not DMs. Follow pagination until you have them all.
    This is read-only. Never post or change anything.
    Write a JSON array to \(out.path) with exactly this shape and nothing else: [{"id": string, "name": string}], where name has no leading #. Sort by name.
    """
    let data = try await runAgent(prompt, output: out, name: "slack-channels")
    let channels = try JSONDecoder().decode([SlackChannel].self, from: data)
    try data.write(to: channelsFile)
    return channels
}
