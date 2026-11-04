import Foundation

struct SessionTurn: Equatable {
    let you: Bool
    let text: String
}

private func texts(_ content: Any?) -> String {
    if let s = content as? String { return s }
    return ((content as? [[String: Any]]) ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
}

func sessionTurns(_ data: Data) -> (cwd: String?, turns: [SessionTurn]) {
    var cwd: String?
    var turns: [SessionTurn] = []
    for line in data.split(separator: UInt8(ascii: "\n")) {
        guard let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], d["isSidechain"] as? Bool != true else { continue }
        cwd = cwd ?? d["cwd"] as? String
        let message = d["message"] as? [String: Any]
        let role = message?["role"] as? String
        guard role == "user" || role == "assistant" else { continue }
        let text = texts(message?["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, role == "assistant" || !(text.hasPrefix("<") || text.hasPrefix("[Request interrupted")) else { continue }
        turns.append(SessionTurn(you: role == "user", text: text))
    }
    return (cwd, turns)
}

func sessionDigest(tool: String, cwd: String?, start: Date, end: Date, turns: [SessionTurn], cap: Int = 40_000) -> String? {
    guard turns.filter(\.you).count >= 2, let first = turns.first(where: \.you) else { return nil }
    let clip = { (s: String) in s.count > 1500 ? s.prefix(1500) + "…" : s }
    let entries = turns.map { "**\($0.you ? "You" : "Agent"):** \(clip($0.text))" }
    var tail: [String] = [], size = entries[0].count
    for e in entries.dropFirst().reversed() {
        guard size + e.count <= cap else { break }
        tail.insert(e, at: 0)
        size += e.count
    }
    let skipped = entries.count - 1 - tail.count
    let title = first.text.split(whereSeparator: \.isNewline).first.map { String($0.prefix(80)) } ?? "Session"
    return ([
        "# \(title)", "",
        "\(tool) session in \(cwd ?? "an unknown folder"), \(iso.string(from: start)) to \(iso.string(from: end)).", "",
        entries[0],
    ] + (skipped > 0 ? ["", "*(\(skipped) earlier messages left out)*"] : []) + tail.flatMap { ["", $0] } + [""]).joined(separator: "\n")
}

let sessionRoots: [(tool: String, folder: URL)] = [
    ("pi", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/sessions")),
    ("Claude Code", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")),
]

func digestSessions(into archive: URL, roots: [(tool: String, folder: URL)] = sessionRoots, now: Date = Date(), days: Int = 14) -> [String] {
    let fm = FileManager.default
    try? fm.createDirectory(at: archive, withIntermediateDirectories: true)
    let cutoff = now.addingTimeInterval(-Double(days) * 86400), idle = now.addingTimeInterval(-30 * 60)
    let modified = { (url: URL) in (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
    for root in roots {
        let projects = (try? fm.contentsOfDirectory(at: root.folder, includingPropertiesForKeys: nil)) ?? []
        for file in projects.flatMap({ (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] }) where file.pathExtension == "jsonl" {
            guard let end = modified(file), end > cutoff, end < idle else { continue }
            let out = archive.appendingPathComponent("\(root.tool == "pi" ? "pi" : "claude")-\(file.deletingPathExtension().lastPathComponent).md")
            if let done = modified(out), abs(done.timeIntervalSince(end)) < 1 { continue }
            guard let data = try? Data(contentsOf: file) else { continue }
            let (cwd, turns) = sessionTurns(data)
            let start = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? end
            let digest = sessionDigest(tool: root.tool, cwd: cwd, start: start, end: end, turns: turns) ?? ""
            guard (try? digest.write(to: out, atomically: true, encoding: .utf8)) != nil else { continue }
            try? fm.setAttributes([.modificationDate: end], ofItemAtPath: out.path)
        }
    }
    return ((try? fm.contentsOfDirectory(at: archive, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? [])
        .compactMap { url -> (String, Date)? in
            guard let date = modified(url), date > cutoff, ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0 else { return nil }
            return (url.path, date)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
}
