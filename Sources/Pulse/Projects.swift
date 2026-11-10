import Foundation

struct Project: Equatable {
    let id: String
    let root: URL

    var dir: URL { root.appendingPathComponent("projects/\(id)") }
    var file: URL { dir.appendingPathComponent("project.json") }
    var db: URL { dir.appendingPathComponent("pulse.db") }
    var name: String { (fields?["name"] as? String) ?? id }
    var fields: [String: Any]? { (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }

    static let keys = ["githubOrg", "githubAccount", "monthlyPRTarget", "repoPath", "worktreeRoot", "slack", "slackChannels", "mail", "mailDays"]
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

    var folders: [String] { ["repoPath", "worktreeRoot"].compactMap { fields?[$0] as? String }.filter { !$0.isEmpty }.map(expand) }

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
        var fields: [String: Any] = ["name": id == "default" ? "Default" : id.prefix(1).uppercased() + id.dropFirst()]
        for k in keys { fields[k] = global.removeValue(forKey: k) }
        try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys]).write(to: project.file)
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
