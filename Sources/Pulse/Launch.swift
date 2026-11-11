import AppKit
import UniformTypeIdentifiers

enum App: String {
    case slack = "Slack", linear = "Linear"

    var url: URL { URL(fileURLWithPath: "/Applications/\(rawValue).app") }
}

let slackState = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Slack/storage/root-state.json")

func slackDeepLink(_ url: URL, state: URL = slackState) -> URL? {
    guard let host = url.host, host.hasSuffix(".slack.com"), let i = url.pathComponents.firstIndex(of: "archives"), i + 1 < url.pathComponents.count,
          let root = (try? JSONSerialization.jsonObject(with: Data(contentsOf: state))) as? [String: Any],
          let team = ((root["workspaces"] as? [String: [String: Any]]) ?? [:]).first(where: { $0.value["domain"] as? String == String(host.dropLast(".slack.com".count)) })?.key
    else { return nil }
    var items = [URLQueryItem(name: "team", value: team), URLQueryItem(name: "id", value: url.pathComponents[i + 1])]
    if i + 2 < url.pathComponents.count, case let p = url.pathComponents[i + 2], p.hasPrefix("p"), p.count > 7 {
        let digits = p.dropFirst()
        items.append(URLQueryItem(name: "message", value: "\(digits.dropLast(6)).\(digits.suffix(6))"))
    }
    if let thread = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "thread_ts" })?.value {
        items.append(URLQueryItem(name: "thread_ts", value: thread))
    }
    var c = URLComponents()
    c.scheme = "slack"
    c.host = "channel"
    c.queryItems = items
    return c.url
}

func openLink(_ url: URL) {
    open(url, in: ["slack": App.slack, "linear": .linear][sourceKind(url, given: "")])
}

func openSource(_ url: URL, kind: String) {
    open(url, in: ["slack": App.slack, "linear": .linear][kind])
}

func open(_ url: URL, in app: App? = nil) {
    if app == .slack {
        NSWorkspace.shared.open(slackDeepLink(url) ?? url)
        return
    }
    guard let app, FileManager.default.fileExists(atPath: app.url.path) else {
        NSWorkspace.shared.open(url)
        return
    }
    NSWorkspace.shared.open([url], withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())
}

func adoptLoginShellPath() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
    p.arguments = ["-ilc", "printf '\\n__PULSE_PATH__%s' \"$PATH\""]
    let pipe = Pipe()
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return }
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
    p.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
    guard p.terminationStatus == 0, let marker = out.range(of: "\n__PULSE_PATH__", options: .backwards) else { return }
    let path = out[marker.upperBound...]
    if !path.isEmpty { setenv("PATH", String(path), 1) }
}

@discardableResult
func shell(_ command: String) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", command]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw SyncError(description: "\(command)\n\(out)") }
    return out
}

func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func repoName(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }

func githubSlug(_ url: String) -> String? {
    guard let r = url.range(of: #"github\.com[:/]([^/\s]+/[^/\s]+?)(\.git)?(/|$)"#, options: .regularExpression) else { return nil }
    return url[r].replacingOccurrences(of: #"^github\.com[:/]|(\.git)?/?$"#, with: "", options: .regularExpression).lowercased()
}

func repoSlugs(_ repos: [String]) -> [String: String] {
    Dictionary(uniqueKeysWithValues: repos.compactMap { repo in
        (try? shell("git -C \(quoted(repo)) remote get-url origin")).flatMap(githubSlug).map { (repo, $0) }
    })
}

func worktrees(_ repos: [String]) -> [String: String] {
    var result: [String: String] = [:]
    for repo in repos {
        var path: String?
        for line in ((try? shell("git -C \(quoted(repo)) worktree list --porcelain")) ?? "").split(separator: "\n") {
            if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
            if line.hasPrefix("branch refs/heads/"), let path { result[String(line.dropFirst(18))] = path }
        }
    }
    return result
}

func localBranches(_ repos: [String]) -> [String: String] {
    var result: [String: String] = [:]
    for repo in repos.reversed() {
        for branch in ((try? shell("git -C \(quoted(repo)) for-each-ref --format='%(refname:short)' refs/heads")) ?? "").split(separator: "\n") { result[String(branch)] = repo }
    }
    return result
}

func pickRepo(pr: URL?, branch: String?, ticket: String?, repos: [String], slugs: [String: String], branches: [String: String], chosen: [String: String]) -> String? {
    let prSlug = pr.flatMap { githubSlug($0.absoluteString) }
    return repos.first { prSlug != nil && slugs[$0] == prSlug }
        ?? branch.flatMap { branches[$0] }.flatMap { b in repos.first { $0 == b } }
        ?? ticket.flatMap { chosen[$0] }.flatMap { c in repos.first { $0 == c } }
        ?? repos.first
}

func worktree(for branch: String, ticket: String, repo: String, in code: Connections) throws -> String {
    if let existing = worktrees(code.repos)[branch] { return existing }
    let path = "\(code.worktrees)/\(ticket.lowercased())/\(repoName(repo))"
    let git = "git -C \(quoted(repo))"
    if (try? shell("\(git) rev-parse --verify --quiet refs/heads/\(quoted(branch))")) != nil {
        try shell("\(git) worktree add \(quoted(path)) \(quoted(branch))")
    } else {
        let base = try shell("\(git) symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main").trimmingCharacters(in: .whitespacesAndNewlines)
        try shell("\(git) fetch --quiet origin && \(git) worktree add -b \(quoted(branch)) \(quoted(path)) \(quoted(base))")
    }
    return path
}

private var zedReusesWindows: Bool {
    let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/zed/settings.json")
    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    return text.range(of: #""cli_default_open_behavior"\s*:\s*"new_window""#, options: .regularExpression) != nil
}

func openInIDE(_ ide: IDE, path: String, prompt: String? = nil) throws {
    if ide == .zed, FileManager.default.fileExists(atPath: "/usr/local/bin/zed") {
        try shell("/usr/local/bin/zed \(zedReusesWindows ? "" : "-n ")\(quoted(path))")
    } else {
        try shell("open -a \(quoted(ide.app.path)) \(quoted(path))")
    }
    guard let prompt else { return }
    if let url = ide.promptURL(prompt) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { NSWorkspace.shared.open(url) }
    } else {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
    }
}

let terminal = NSWorkspace.shared.urlForApplication(toOpen: .shellScript) ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")

var terminalName: String { terminal.deletingPathExtension().lastPathComponent }

func openCommandInTerminal(_ command: String, in path: String = NSHomeDirectory(), scriptName: String = "pulse") throws {
    let full = "cd \(quoted(path)) && \(command)"
    if terminalName == "Ghostty" {
        try shell("open -na \(quoted(terminal.path)) --args --working-directory=\(quoted(path)) -e /bin/zsh -lc \(quoted(full))")
        return
    }
    let script = project.dir.appendingPathComponent("prompts/\(scriptName).command")
    try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/zsh -l\n\(full)\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
}

func openAgentInTerminal(_ agent: Agent, path: String, promptFile: URL) throws {
    try openCommandInTerminal(agent.command.replacingOccurrences(of: "{prompt}", with: quoted(promptFile.path)), in: path,
                              scriptName: promptFile.deletingPathExtension().lastPathComponent)
}
