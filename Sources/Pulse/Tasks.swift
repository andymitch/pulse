import Foundation

struct PulseTask: Codable, Equatable {
    let id: String
    var title, why, url: String
    var source, reply: String?
}

struct TaskChanges: Decodable {
    struct Add: Decodable { let title, why, url: String; let source, reply: String? }
    struct Update: Decodable { let id: String; let title, why, url, reply: String? }
    struct Close: Decodable { let id: String; let reason: String? }
    let add: [Add]?
    let update: [Update]?
    let close: [Close]?
}

func applyTaskChanges(_ changes: TaskChanges, to tasks: [PulseTask], open: Set<String>, newID: () -> String = { UUID().uuidString }) -> (tasks: [PulseTask], closed: [String]) {
    var tasks = tasks
    let edit = { (i: Int, title: String?, why: String?, url: String?, reply: String?) in
        if let title, !title.isEmpty { tasks[i].title = title }
        if let why { tasks[i].why = why }
        if let url = threadLink(url), !url.isEmpty { tasks[i].url = url }
        if let reply { tasks[i].reply = reply.isEmpty ? nil : reply }
    }
    for u in changes.update ?? [] {
        if let i = tasks.firstIndex(where: { $0.id == u.id }) { edit(i, u.title, u.why, u.url, u.reply) }
    }
    for a in changes.add ?? [] where !a.title.isEmpty {
        let url = threadLink(a.url) ?? a.url
        if let i = tasks.firstIndex(where: { open.contains($0.id) && $0.url == url }) {
            edit(i, a.title, a.why, nil, a.reply)
        } else {
            tasks.append(PulseTask(id: newID(), title: a.title, why: a.why, url: url, source: a.source, reply: a.reply))
        }
    }
    var closed: [String] = []
    for c in changes.close ?? [] {
        guard let i = tasks.firstIndex(where: { $0.id == c.id }) else { continue }
        if let reason = c.reason, !reason.isEmpty { tasks[i].why = reason }
        tasks[i].reply = nil
        closed.append(c.id)
    }
    return (tasks, closed)
}

struct TaskMarks {
    var done: [String: String] = [:]
    var later: Set<String> = []
    var removed: [String: String] = [:]
}

extension DB {
    func tasks() -> [PulseTask] {
        ((try? query("SELECT id, title, why, url, source, reply FROM tasks ORDER BY rowid")) ?? []).compactMap { r in
            guard let id = r[0] as? String, let title = r[1] as? String, let url = r[3] as? String else { return nil }
            return PulseTask(id: id, title: title, why: r[2] as? String ?? "", url: url, source: r[4] as? String, reply: r[5] as? String)
        }
    }

    func saveTask(_ t: PulseTask) throws {
        try query("""
            INSERT INTO tasks (id, title, why, url, source, reply) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET title = excluded.title, why = excluded.why, url = excluded.url, source = excluded.source, reply = excluded.reply
            """, [t.id, t.title, t.why, t.url, t.source, t.reply])
    }

    func deleteTasks(_ ids: Set<String>) throws {
        for id in ids {
            try query("DELETE FROM tasks WHERE id = ?", [id])
            try query("DELETE FROM task_marks WHERE id = ?", [id])
        }
    }

    func marks() -> TaskMarks {
        var m = TaskMarks()
        for r in (try? query("SELECT id, done, later, removed FROM task_marks")) ?? [] {
            guard let id = r[0] as? String else { continue }
            m.done[id] = r[1] as? String
            if r[2] as? Int == 1 { m.later.insert(id) }
            m.removed[id] = r[3] as? String
        }
        return m
    }

    func mark(_ id: String, done: String?? = nil, later: Bool? = nil, removed: String?? = nil) throws {
        try transaction {
            try query("INSERT INTO task_marks (id) VALUES (?) ON CONFLICT (id) DO NOTHING", [id])
            if let done { try query("UPDATE task_marks SET done = ? WHERE id = ?", [done, id]) }
            if let later { try query("UPDATE task_marks SET later = ? WHERE id = ?", [later ? 1 : 0, id]) }
            if let removed { try query("UPDATE task_marks SET removed = ? WHERE id = ?", [removed, id]) }
            try query("DELETE FROM task_marks WHERE id = ? AND done IS NULL AND later = 0 AND removed IS NULL", [id])
        }
    }

    func clearMarks(_ ids: Set<String>) throws {
        for id in ids { try query("DELETE FROM task_marks WHERE id = ?", [id]) }
    }
}

func taskPrompt(_ task: PulseTask) -> String {
    var parts = ["Help me get this task done: \(task.title)"]
    if !task.why.isEmpty { parts.append("Why: \(task.why)") }
    parts.append("Link: \(task.url)\nStart by reading what the link points to.")
    if let reply = task.reply, !reply.isEmpty { parts.append("Suggested reply:\n\(reply)") }
    parts.append("It's on my Pulse task list with id \(task.id). Once it's done, mark it done with the Pulse MCP update_task tool.")
    return parts.joined(separator: "\n\n")
}
