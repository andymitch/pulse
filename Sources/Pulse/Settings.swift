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
    var githubOrg = ""
    var githubAccount = ""
    var monthlyPRTarget = 40
    var repoPath = ""
    var worktreeRoot = "~/worktrees"
    var slack = true
    var slackChannels: [SlackChannel] = []
    var mail = false
    var mailDays = 3
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

    static func load(_ data: Data? = try? Data(contentsOf: file), project projectData: Data? = try? Data(contentsOf: project.file)) -> Settings {
        let defaults = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings()))) as? [String: Any] ?? [:]
        var saved = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if saved["recordMeetings"] == nil, let meetings = saved["meetings"] as? [String] {
            saved["recordMeetings"] = meetings.contains("record") || meetings.contains("superwhisper")
        }
        if saved["slackChannels"] == nil {
            let old = [saved["engineeringChannels"], saved["businessChannels"]].compactMap { $0 as? String }.joined(separator: ", ")
            let regex = try! NSRegularExpression(pattern: #"#([\w-]+) \((\w+)\)"#)
            let channels = regex.matches(in: old, range: NSRange(old.startIndex..., in: old)).map { m in
                ["id": (old as NSString).substring(with: m.range(at: 2)), "name": (old as NSString).substring(with: m.range(at: 1))]
            }
            if !channels.isEmpty { saved["slackChannels"] = channels }
        }
        let own = (projectData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]).filter { Project.keys.contains($0.key) }
        let merged = defaults.merging(saved) { _, new in new }.merging(own) { _, new in new }
        return (try? JSONSerialization.data(withJSONObject: merged)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }

    func save() throws {
        guard let all = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any] else { return }
        try FileManager.default.createDirectory(at: project.dir, withIntermediateDirectories: true)
        let own = (project.fields ?? [:]).merging(all.filter { Project.keys.contains($0.key) }) { _, new in new }
        try JSONSerialization.data(withJSONObject: own, options: [.prettyPrinted, .sortedKeys]).write(to: project.file)
        try JSONSerialization.data(withJSONObject: all.filter { !Project.keys.contains($0.key) }, options: [.prettyPrinted, .sortedKeys]).write(to: Settings.file)
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
