import AppKit
import UniformTypeIdentifiers

enum App: String {
    case slack = "Slack", linear = "Linear"

    var url: URL { URL(fileURLWithPath: "/Applications/\(rawValue).app") }
}

func open(_ url: URL, in app: App? = nil) {
    guard let app, FileManager.default.fileExists(atPath: app.url.path) else {
        NSWorkspace.shared.open(url)
        return
    }
    NSWorkspace.shared.open([url], withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())
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

func worktrees() -> [String: String] {
    guard settings.codeReady else { return [:] }
    let out = (try? shell("git -C \(quoted(settings.repo)) worktree list --porcelain")) ?? ""
    var result: [String: String] = [:]
    var path: String?
    for line in out.split(separator: "\n") {
        if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
        if line.hasPrefix("branch refs/heads/"), let path { result[String(line.dropFirst(18))] = path }
    }
    return result
}

func localBranchNames() -> Set<String> {
    guard settings.codeReady else { return [] }
    let out = (try? shell("git -C \(quoted(settings.repo)) for-each-ref --format='%(refname:short)' refs/heads")) ?? ""
    return Set(out.split(separator: "\n").map(String.init))
}

func worktree(for branch: String, ticket: String) throws -> String {
    guard settings.codeReady else { throw SyncError(description: "Set the repository path in Pulse settings first.") }
    if let existing = worktrees()[branch] { return existing }
    let path = "\(settings.worktrees)/\(ticket.lowercased())/\(settings.repoName)"
    let repo = quoted(settings.repo)
    let hasBranch = (try? shell("git -C \(repo) rev-parse --verify --quiet refs/heads/\(quoted(branch))")) != nil
    if hasBranch {
        try shell("git -C \(repo) worktree add \(quoted(path)) \(quoted(branch))")
    } else {
        let base = try shell("git -C \(repo) symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try shell("git -C \(repo) fetch --quiet origin && git -C \(repo) worktree add -b \(quoted(branch)) \(quoted(path)) \(quoted(base))")
    }
    return path
}

func openInIDE(_ ide: IDE, path: String, prompt: String? = nil) throws {
    if ide == .zed, FileManager.default.fileExists(atPath: "/usr/local/bin/zed") {
        try shell("/usr/local/bin/zed -n \(quoted(path))")
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
    let script = Settings.dir.appendingPathComponent("prompts/\(scriptName).command")
    try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/zsh -l\n\(full)\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
}

func openAgentInTerminal(_ agent: Agent, path: String, promptFile: URL) throws {
    try openCommandInTerminal(agent.command.replacingOccurrences(of: "{prompt}", with: quoted(promptFile.path)), in: path,
                              scriptName: promptFile.deletingPathExtension().lastPathComponent)
}
