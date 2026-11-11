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

struct Settings: Codable, Equatable {
    var connections = Connections()
    var recordMeetings = true
    var ides: [IDE] = [.zed]
    var agents: [Agent] = Settings.agentPresets
    var briefingCommand = Settings.briefingPresets[0].command
    var briefingHour = 7
    var naturalVoice = false
    var voiceAsked = false
    var solidBackground = false
    var betaUpdates = false
    var agentAccess = true
    var hotkey = Hotkey.standard
    var defaultProject = ""

    static let agentPresets = [
        Agent(name: "pi", command: "pi @{prompt}"),
        Agent(name: "Claude Code", command: "claude \"$(cat {prompt})\"", enabled: false),
    ]

    static let briefingPresets: [(name: String, command: String)] = [
        ("pi", "pi -p --no-session @{prompt}"),
        ("Claude Code", "claude -p --permission-mode acceptEdits \"$(cat {prompt})\""),
    ]

    static let dir: URL = {
        guard demoMode || CommandLine.arguments.contains("--self-test") else { return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pulse") }
        let demo = FileManager.default.temporaryDirectory.appendingPathComponent(demoMode ? "PulseDemo" : "PulseSelfTest-\(getpid())")
        try? FileManager.default.removeItem(at: demo)
        try? FileManager.default.createDirectory(at: demo, withIntermediateDirectories: true)
        return demo
    }()
    private static let file = dir.appendingPathComponent("settings.json")

    static func load(_ data: Data? = try? Data(contentsOf: file), connections: Connections? = project.connections) -> Settings {
        let defaults = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings()))) as? [String: Any] ?? [:]
        var saved = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if saved["recordMeetings"] == nil, let meetings = saved["meetings"] as? [String] {
            saved["recordMeetings"] = meetings.contains("record") || meetings.contains("superwhisper")
        }
        let merged = defaults.merging(saved) { _, new in new }
        var loaded = (try? JSONSerialization.data(withJSONObject: merged)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        loaded.connections = connections ?? Connections()
        return loaded
    }

    func save() throws {
        guard var all = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any] else { return }
        try project.save(connections)
        all.removeValue(forKey: "connections")
        try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]).write(to: Settings.file)
    }

    var githubAccount: String { connections.github?.account ?? "" }
    var githubOrg: String { connections.github?.org ?? "" }
    var repo: String { expand(connections.code?.repo ?? "") }
    var repoName: String { URL(fileURLWithPath: repo).lastPathComponent }
    var worktrees: String { expand(connections.code?.worktrees ?? "") }
    var codeReady: Bool { !(connections.code?.repo ?? "").isEmpty }
    var enabledAgents: [Agent] { agents.filter(\.enabled) }
    var enabledIDEs: [IDE] { ides.filter(\.installed) }
}

func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

var settings: Settings = {
    if demoMode { return .demo }
    var s = Settings.load()
    if var github = s.connections.github, github.account.isEmpty || github.org.isEmpty, let account = ghAccounts().first {
        if github.account.isEmpty { github.account = account }
        if github.org.isEmpty { github.org = ghOrgs(account: account).first ?? "" }
        s.connections.github = github
        try? s.save()
    }
    return s
}()
