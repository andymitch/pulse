import AppKit

struct Agent: Codable, Hashable {
    var name: String
    var command: String
    var enabled = true

    var brand: Brand? {
        let n = name.lowercased()
        return n.contains("claude") ? .claude : n == "pi" ? .pi : nil
    }
}

enum IDE: String, Codable, CaseIterable {
    case zed, cursor, vscode

    var name: String {
        switch self {
        case .zed: "Zed"
        case .cursor: "Cursor"
        case .vscode: "VS Code"
        }
    }

    var app: URL {
        let names: [IDE: String] = [.zed: "Zed", .cursor: "Cursor", .vscode: "Visual Studio Code"]
        return URL(fileURLWithPath: "/Applications/\(names[self]!).app")
    }

    var installed: Bool { FileManager.default.fileExists(atPath: app.path) }

    var brand: Brand {
        switch self {
        case .zed: .zed
        case .cursor: .cursor
        case .vscode: .vscode
        }
    }

    func promptURL(_ prompt: String) -> URL? {
        var c: URLComponents
        switch self {
        case .zed:
            c = URLComponents(string: "zed://agent")!
            c.queryItems = [URLQueryItem(name: "prompt", value: prompt)]
        case .cursor:
            c = URLComponents(string: "cursor://anysphere.cursor-deeplink/prompt")!
            c.queryItems = [URLQueryItem(name: "text", value: prompt)]
        case .vscode:
            return nil
        }
        return c.url
    }
}

enum MeetingSource: String, Codable, CaseIterable {
    case record, otter, loom

    var name: String { self == .record ? "Record meetings" : rawValue.capitalized }

    var setup: String {
        switch self {
        case .record: "Pulse records Google Meet calls, Slack huddles and calendar meetings once they use your mic, transcribes them on this Mac and saves a summary. The first meeting downloads about 500 MB of speech models. macOS asks for microphone, screen and system audio recording, and calendar access."
        case .otter: "Connect Otter to Slack, or have it email summaries, so its notes land somewhere the briefing reads."
        case .loom: "Loom links shared in Slack or email are read as meeting records. Nothing to set up."
        }
    }
}

struct Settings: Codable, Equatable {
    var githubOrg = ""
    var githubAccount = ""
    var repoPath = ""
    var worktreeRoot = "~/worktrees"
    var slack = true
    var slackChannels: [SlackChannel] = []
    var mail = false
    var mailDays = 3
    var meetings: [MeetingSource] = [.record]
    var ides: [IDE] = [.zed]
    var agents: [Agent] = Settings.agentPresets
    var briefingCommand = Settings.briefingPresets[0].command
    var briefingHour = 7
    var naturalVoice = false
    var voiceAsked = false
    var solidBackground = false
    var betaUpdates = false
    var hotkey = Hotkey.standard

    static let agentPresets = [
        Agent(name: "pi", command: "pi @{prompt}"),
        Agent(name: "Claude Code", command: "claude \"$(cat {prompt})\"", enabled: false),
    ]

    static let briefingPresets: [(name: String, command: String)] = [
        ("pi", "pi -p --no-session @{prompt}"),
        ("Claude Code", "claude -p --permission-mode acceptEdits \"$(cat {prompt})\""),
    ]

    static let dir: URL = {
        guard demoMode else { return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pulse") }
        let demo = FileManager.default.temporaryDirectory.appendingPathComponent("PulseDemo")
        try? FileManager.default.removeItem(at: demo)
        try? FileManager.default.createDirectory(at: demo, withIntermediateDirectories: true)
        return demo
    }()
    private static let file = dir.appendingPathComponent("settings.json")

    static func load(_ data: Data? = try? Data(contentsOf: file)) -> Settings {
        let defaults = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings()))) as? [String: Any] ?? [:]
        var saved = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if let meetings = saved["meetings"] as? [String] {
            saved["meetings"] = meetings.map { $0 == "superwhisper" ? MeetingSource.record.rawValue : $0 }.filter { MeetingSource(rawValue: $0) != nil }
        }
        if saved["slackChannels"] == nil {
            let old = [saved["engineeringChannels"], saved["businessChannels"]].compactMap { $0 as? String }.joined(separator: ", ")
            let regex = try! NSRegularExpression(pattern: #"#([\w-]+) \((\w+)\)"#)
            let channels = regex.matches(in: old, range: NSRange(old.startIndex..., in: old)).map { m in
                ["id": (old as NSString).substring(with: m.range(at: 2)), "name": (old as NSString).substring(with: m.range(at: 1))]
            }
            if !channels.isEmpty { saved["slackChannels"] = channels }
        }
        let merged = defaults.merging(saved) { _, new in new }
        return (try? JSONSerialization.data(withJSONObject: merged)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: Settings.dir, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: Settings.file)
    }

    var repo: String { expand(repoPath) }
    var repoName: String { URL(fileURLWithPath: repo).lastPathComponent }
    var worktrees: String { expand(worktreeRoot) }
    var enabledAgents: [Agent] { agents.filter(\.enabled) }
    var enabledIDEs: [IDE] { ides.filter(\.installed) }
    var codeReady: Bool { !repoPath.isEmpty }
}

func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

var settings: Settings = {
    if demoMode { return .demo }
    var s = Settings.load()
    if s.githubAccount.isEmpty || s.githubOrg.isEmpty, let account = ghAccounts().first {
        if s.githubAccount.isEmpty { s.githubAccount = account }
        if s.githubOrg.isEmpty { s.githubOrg = ghOrgs(account: account).first ?? "" }
        try? s.save()
    }
    return s
}()
