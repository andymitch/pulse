import Foundation

struct Connections: Codable, Equatable {
    struct GitHub: Codable, Equatable { var account = "", org = "", monthlyPRTarget = 40 }
    struct Linear: Codable, Equatable {}
    struct Code: Codable, Equatable {
        var repos: [String] = [], worktrees = "~/worktrees"
        init(repos: [String] = [], worktrees: String = "~/worktrees") { self.repos = repos; self.worktrees = worktrees }
        private enum Keys: String, CodingKey { case repos, repo, worktrees }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            repos = try c.decodeIfPresent([String].self, forKey: .repos) ?? [c.decodeIfPresent(String.self, forKey: .repo)].compactMap { $0 }.filter { !$0.isEmpty }
            worktrees = try c.decodeIfPresent(String.self, forKey: .worktrees) ?? "~/worktrees"
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(repos, forKey: .repos)
            try c.encode(worktrees, forKey: .worktrees)
        }
    }
    struct Slack: Codable, Equatable { var channels: [SlackChannel] = [] }
    struct Mail: Codable, Equatable { var days = 3 }
    var github: GitHub?
    var linear: Linear?
    var code: Code?
    var slack: Slack?
    var mail: Mail?

    init() {}

    init(flat f: [String: Any], linear hasKey: Bool) {
        let text = { (key: String) in f[key] as? String ?? "" }
        github = GitHub(account: text("githubAccount"), org: text("githubOrg"), monthlyPRTarget: f["monthlyPRTarget"] as? Int ?? 40)
        linear = hasKey ? Linear() : nil
        code = text("repoPath").isEmpty ? nil : Code(repos: [text("repoPath")], worktrees: f["worktreeRoot"] as? String ?? "~/worktrees")
        slack = f["slack"] as? Bool ?? true ? Slack(channels: (f["slackChannels"] as? [[String: String]] ?? []).compactMap { c in c["id"].flatMap { id in c["name"].map { SlackChannel(id: id, name: $0) } } }) : nil
        mail = f["mail"] as? Bool ?? false ? Mail(days: f["mailDays"] as? Int ?? 3) : nil
    }

    static let flatKeys = ["githubOrg", "githubAccount", "monthlyPRTarget", "repoPath", "worktreeRoot", "slack", "slackChannels", "mail", "mailDays"]
}

struct Project: Equatable {
    let id: String
    let root: URL

    var dir: URL { root.appendingPathComponent("projects/\(id)") }
    var file: URL { dir.appendingPathComponent("project.json") }
    var db: URL { dir.appendingPathComponent("pulse.db") }
    var name: String { (fields?["name"] as? String) ?? id }
    var fields: [String: Any]? { (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }

    var connections: Connections {
        guard let fields else { return Connections() }
        if let saved = fields["connections"], let data = try? JSONSerialization.data(withJSONObject: saved),
           let decoded = try? JSONDecoder().decode(Connections.self, from: data) { return decoded }
        return Connections(flat: fields, linear: FileManager.default.fileExists(atPath: dir.appendingPathComponent("linear-key").path))
    }

    func save(_ connections: Connections) throws {
        var fields = (self.fields ?? ["name": name]).filter { !Connections.flatKeys.contains($0.key) }
        fields["connections"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(connections))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys]).write(to: file)
    }
    private static let globalFiles: Set<String> = ["settings.json", "Voice", "projects", ".DS_Store"]

    static func all(in root: URL) -> [Project] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("projects").path)) ?? []).sorted()
            .map { Project(id: $0, root: root) }
            .filter { FileManager.default.fileExists(atPath: $0.file.path) }
    }

    static func named(_ id: String, in root: URL) -> Project? { all(in: root).first { $0.id == id } }

    static func resolve(in root: URL, asked: String? = nil, folder: String? = nil) -> Project? {
        let projects = all(in: root)
        if let asked { return projects.first { $0.id == asked } }
        if let folder, let match = projects.first(where: { inFolders(folder, $0.folders) }) { return match }
        let global = (try? Data(contentsOf: root.appendingPathComponent("settings.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (global?["defaultProject"] as? String).flatMap { id in projects.first { $0.id == id } }
    }

    var folders: [String] { ((connections.code?.repos ?? []) + [connections.code?.worktrees ?? ""]).filter { !$0.isEmpty }.map(expand) }

    static func migrate(_ root: URL, legacyLinearKey: () -> Data? = { nil }) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard all(in: root).isEmpty else { return }
        let settingsFile = root.appendingPathComponent("settings.json")
        var global = (try? Data(contentsOf: settingsFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let workspace = (try? DB(path: root.appendingPathComponent("pulse.db").path, readOnly: true))?.meta("linear_workspace")
        let id = [workspace, global["githubOrg"] as? String].compactMap { $0?.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" } }.first { !$0.isEmpty } ?? "default"
        let project = Project(id: id, root: root)
        try fm.createDirectory(at: project.dir, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: root.path) where !globalFiles.contains(name) {
            try fm.moveItem(at: root.appendingPathComponent(name), to: project.dir.appendingPathComponent(name))
        }
        let key = project.dir.appendingPathComponent("linear-key")
        if !fm.fileExists(atPath: key.path), let legacy = legacyLinearKey() { try writePrivate(legacy, to: key) }
        try JSONSerialization.data(withJSONObject: ["name": id == "default" ? "Default" : id.prefix(1).uppercased() + id.dropFirst()]).write(to: project.file)
        try project.save(Connections(flat: global, linear: fm.fileExists(atPath: key.path)))
        for k in Connections.flatKeys { global.removeValue(forKey: k) }
        global["defaultProject"] = id
        try JSONSerialization.data(withJSONObject: global, options: [.prettyPrinted, .sortedKeys]).write(to: settingsFile)
        guard fm.fileExists(atPath: project.db.path) else { return }
        try "Pulse moved this to projects/\(id)/pulse.db. This version of Pulse is too old to read it.\n".write(to: root.appendingPathComponent("pulse.db"), atomically: true, encoding: .utf8)
    }
}

func launchProject() -> Project? {
    let asked = CommandLine.arguments.firstIndex(of: "--project").flatMap { CommandLine.arguments.dropFirst($0 + 1).first }
    return Project.resolve(in: Settings.dir, asked: asked, folder: asked == nil ? FileManager.default.currentDirectoryPath : nil)
}

let project: Project = {
    try? Project.migrate(Settings.dir, legacyLinearKey: legacyLinearKey)
    return launchProject() ?? Project.all(in: Settings.dir).first ?? Project(id: "default", root: Settings.dir)
}()
