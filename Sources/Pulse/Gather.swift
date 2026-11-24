import Foundation

struct SourceItem: Codable, Equatable {
    let kind, title, url: String
    var author, date, text: String?
    var size: Int?
}

private struct Login: Decodable { let login: String }

private struct LinearComment: Decodable { let body: String; let user: Named?; let createdAt: String }
private struct LinearIssue: Decodable {
    struct Comments: Decodable { let nodes: [LinearComment] }
    let identifier, title, url: String
    let description: String?
    let creator: Named?
    let createdAt: String
    let state: Named?
    let assignee: Named?
    let comments: Comments?
}
private struct LinearDocument: Decodable { let title, url, createdAt: String; let content: String?; let creator: Named? }

private struct GitHubNote: Decodable { let author: Login?; let body: String; let at: String?; let state: String? }
private struct GitHubThread: Decodable {
    struct Notes: Decodable { let nodes: [GitHubNote] }
    let number: Int?
    let title, url: String?
    let author: Login?
    let createdAt, updatedAt: String?
    let body: String?
    let comments: Notes?
    let reviews: Notes?
}

private let githubThreadFields = """
    number title url author { login } createdAt updatedAt body
    comments(last: 50) { nodes { author { login } body at: createdAt } }
    """
private let githubThreadQuery = "... on Issue { \(githubThreadFields) } ... on PullRequest { \(githubThreadFields) reviews(last: 30) { nodes { author { login } body at: submittedAt state } } }"

enum SourceLink: Equatable {
    case linearIssue(String), linearDocument(String), github(owner: String, repo: String, number: Int)

    init?(_ link: String, linearWorkspace: String?, github: Connections.GitHub?) {
        guard let url = URL(string: link), url.scheme == "https" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host {
        case "linear.app":
            guard parts.count >= 3, let workspace = linearWorkspace, parts[0].caseInsensitiveCompare(workspace) == .orderedSame else { return nil }
            switch parts[1] {
            case "issue": self = .linearIssue(parts[2])
            case "document": guard let slug = parts[2].split(separator: "-").last else { return nil }; self = .linearDocument(String(slug))
            default: return nil
            }
        case "github.com":
            guard let github, parts.count >= 4, ["issues", "pull"].contains(parts[2]), let number = Int(parts[3]) else { return nil }
            let repo = "\(parts[0])/\(parts[1])"
            let owned = github.repos.isEmpty
                ? [github.org.isEmpty ? github.account : github.org].contains { $0.caseInsensitiveCompare(parts[0]) == .orderedSame }
                : github.repos.contains { $0.caseInsensitiveCompare(repo) == .orderedSame }
            guard owned else { return nil }
            self = .github(owner: parts[0], repo: parts[1], number: number)
        default:
            return nil
        }
    }
}

private func noteLine(_ who: String?, _ date: String?, _ body: String) -> String {
    "\(who ?? "someone")\(date.map { " (\($0.prefix(10)))" } ?? ""): \(body.trimmingCharacters(in: .whitespacesAndNewlines))"
}

private func linearItem(_ i: LinearIssue) -> SourceItem {
    let head = [i.state.map { "Status: \($0.name)" }, i.assignee.map { "Assignee: \($0.name)" }].compactMap { $0 }.joined(separator: ". ")
    let notes = (i.comments?.nodes ?? []).sorted { $0.createdAt < $1.createdAt }.map { noteLine($0.user?.name, $0.createdAt, $0.body) }
    let text = ([head, i.description ?? ""] + (notes.isEmpty ? [] : ["Comments, oldest first:"] + notes)).filter { !$0.isEmpty }.joined(separator: "\n\n")
    return SourceItem(kind: "linear", title: "\(i.identifier) \(i.title)", url: i.url, author: i.creator?.name, date: String(i.createdAt.prefix(10)), text: text)
}

private func githubItem(_ t: GitHubThread, repo: String, since: String? = nil) -> SourceItem? {
    guard let number = t.number, let title = t.title, let url = t.url else { return nil }
    let human = { (n: GitHubNote) in !(n.author?.login.hasSuffix("[bot]") ?? false) && !n.body.isEmpty && (since.map { s in (n.at ?? "") >= s } ?? true) }
    let notes = ((t.comments?.nodes ?? []) + (t.reviews?.nodes ?? [])).filter(human).sorted { ($0.at ?? "") < ($1.at ?? "") }
        .map { noteLine($0.author?.login, $0.at, ($0.state.map { "[\($0.lowercased())] " } ?? "") + $0.body) }
    let isNew = since.map { (t.createdAt ?? "") >= $0 } ?? true
    let text = ([isNew ? t.body ?? "" : ""] + (notes.isEmpty ? [] : ["Comments and reviews, oldest first:"] + notes)).filter { !$0.isEmpty }.joined(separator: "\n\n")
    return SourceItem(kind: "github", title: "\(repo)#\(number) \(title)", url: url, author: t.author?.login, date: String((t.updatedAt ?? t.createdAt ?? "").prefix(10)), text: text)
}

func fetchSource(_ link: String, connections: Connections, linearWorkspace: String?, linearKey: String?) async throws -> SourceItem {
    guard let target = SourceLink(link, linearWorkspace: connections.linear == nil ? nil : linearWorkspace, github: connections.github) else {
        throw SyncError(description: "Pulse can't fetch \(link): only Linear issues and docs and GitHub issues and PRs from this project's connections.")
    }
    switch target {
    case .linearIssue(let id):
        struct Out: Decodable { let issue: LinearIssue }
        guard let linearKey else { throw SyncError(description: "Linear isn't signed in for this project.") }
        let out: Out = try await gql(linearURL, auth: linearKey, """
            query($id: String!) { issue(id: $id) { identifier title url description createdAt creator { name } state { name } assignee { name }
              comments(first: 100) { nodes { body createdAt user { name } } } } }
            """, ["id": id])
        var item = linearItem(out.issue)
        item.text = item.text.map { String($0.prefix(30000)) }
        return item
    case .linearDocument(let slug):
        struct Out: Decodable { let document: LinearDocument }
        guard let linearKey else { throw SyncError(description: "Linear isn't signed in for this project.") }
        let d: Out = try await gql(linearURL, auth: linearKey, "query($id: String!) { document(id: $id) { title url createdAt content creator { name } } }", ["id": slug])
        return SourceItem(kind: "linear", title: d.document.title, url: d.document.url, author: d.document.creator?.name, date: String(d.document.createdAt.prefix(10)),
                          text: d.document.content.map { String($0.prefix(30000)) })
    case .github(let owner, let repo, let number):
        struct Out: Decodable { struct Repo: Decodable { let issueOrPullRequest: GitHubThread? }; let repository: Repo? }
        let out: Out = try await gql(githubURL, auth: "bearer \(try ghToken(connections.github?.account ?? ""))",
                                     "query($owner: String!, $name: String!, $n: Int!) { repository(owner: $owner, name: $name) { issueOrPullRequest(number: $n) { \(githubThreadQuery) } } }",
                                     ["owner": owner, "name": repo, "n": number])
        guard let thread = out.repository?.issueOrPullRequest, var item = githubItem(thread, repo: "\(owner)/\(repo)") else {
            throw SyncError(description: "GitHub has no \(owner)/\(repo)#\(number).")
        }
        item.text = item.text.map { String($0.prefix(30000)) }
        return item
    }
}

func lookupSources(_ query: String, connections: Connections, linearKey: String?) async throws -> [SourceItem] {
    var found: [SourceItem] = []
    if connections.linear != nil, let linearKey {
        struct Hit: Decodable { let identifier: String?; let title, url, updatedAt: String }
        struct Hits: Decodable { let nodes: [Hit] }
        struct Out: Decodable { let searchIssues: Hits; let searchDocuments: Hits }
        let out: Out = try await gql(linearURL, auth: linearKey, """
            query($q: String!) { searchIssues(term: $q, first: 10) { nodes { identifier title url updatedAt } } searchDocuments(term: $q, first: 5) { nodes { title url updatedAt } } }
            """, ["q": query])
        found += (out.searchIssues.nodes + out.searchDocuments.nodes).map {
            SourceItem(kind: "linear", title: [$0.identifier, $0.title].compactMap { $0 }.joined(separator: " "), url: $0.url, date: String($0.updatedAt.prefix(10)))
        }
    }
    if let github = connections.github {
        struct Hit: Decodable { let number: Int?; let title, url, updatedAt: String?; let author: Login?; let repository: Named? }
        struct Out: Decodable { struct Search: Decodable { let nodes: [Hit] }; let search: Search }
        let scope = github.scope.isEmpty ? "involves:\(github.account)" : github.scope
        let out: Out = try await gql(githubURL, auth: "bearer \(try ghToken(github.account))", """
            query($q: String!) { search(query: $q, type: ISSUE, first: 10) { nodes {
              ... on Issue { number title url updatedAt author { login } repository { name } }
              ... on PullRequest { number title url updatedAt author { login } repository { name } } } } }
            """, ["q": "\(scope) \(query)"])
        found += out.search.nodes.compactMap { h in
            guard let number = h.number, let title = h.title, let url = h.url else { return nil }
            return SourceItem(kind: "github", title: "\(h.repository?.name ?? "")#\(number) \(title)", url: url, author: h.author?.login, date: h.updatedAt.map { String($0.prefix(10)) })
        }
    }
    return found
}

func indexed(_ item: SourceItem, limit: Int = 1500) -> SourceItem {
    guard let text = item.text, text.count > limit else { return item }
    var index = item
    index.text = nil
    index.size = text.count
    return index
}

func gatherLinear(key: String, workspace: String?, since: Date) async throws -> [SourceItem] {
    struct Issue: Decodable { let identifier, title: String; let state: Named?; let assignee: Named? }
    struct Cycle: Decodable { struct Issues: Decodable { let nodes: [Issue] }; struct Team: Decodable { let key, name: String }; let number: Int; let startsAt, endsAt: String; let team: Team; let issues: Issues }
    struct Update: Decodable { let url, createdAt, body: String; let user: Named?; let project: Named?; let initiative: Named? }
    struct Nodes<T: Decodable>: Decodable { let nodes: [T] }
    struct Cycles: Decodable { let cycles: Nodes<Cycle> }
    struct Out: Decodable { let projectUpdates, initiativeUpdates: Nodes<Update>; let documents: Nodes<LinearDocument> }
    let active: Cycles = try await gql(linearURL, auth: key,
        "{ cycles(first: 5, filter: {isActive: {eq: true}}) { nodes { number startsAt endsAt team { key name } issues(first: 100) { nodes { identifier title state { name } assignee { name } } } } } }")
    let out: Out = try await gql(linearURL, auth: key, """
        query($since: DateTimeOrDuration!) {
          projectUpdates(first: 50, filter: {createdAt: {gt: $since}}) { nodes { url createdAt body user { name } project { name } } }
          initiativeUpdates(first: 50, filter: {createdAt: {gt: $since}}) { nodes { url createdAt body user { name } initiative { name } } }
          documents(first: 50, filter: {createdAt: {gt: $since}}) { nodes { title url createdAt content creator { name } } }
        }
        """, ["since": iso.string(from: since)])
    let cycles = active.cycles.nodes.map { c in
        SourceItem(kind: "linear", title: "\(c.team.name) cycle \(c.number), \(c.startsAt.prefix(10)) to \(c.endsAt.prefix(10))",
                   url: "https://linear.app/\(workspace ?? "")/team/\(c.team.key)/cycle/\(c.number)", date: String(c.startsAt.prefix(10)),
                   text: c.issues.nodes.map { i in [i.identifier, i.title, i.state?.name, i.assignee?.name].compactMap { $0 }.joined(separator: " · ") }.joined(separator: "\n"))
    }
    let updates = (out.projectUpdates.nodes + out.initiativeUpdates.nodes).map { u in
        SourceItem(kind: "linear", title: "Status update: \((u.project ?? u.initiative)?.name ?? "")", url: u.url, author: u.user?.name, date: String(u.createdAt.prefix(10)), text: String(u.body.prefix(8000)))
    }
    let docs = out.documents.nodes.map { d in
        indexed(SourceItem(kind: "linear", title: d.title, url: d.url, author: d.creator?.name, date: String(d.createdAt.prefix(10)), text: d.content))
    }
    return cycles + updates + docs
}

func gatherGitHub(token: String, github: Connections.GitHub, since: Date) async throws -> [SourceItem] {
    struct Hit: Decodable { struct Repo: Decodable { let nameWithOwner: String }; let repository: Repo?; let thread: GitHubThread
        init(from decoder: Decoder) throws {
            repository = try? decoder.container(keyedBy: Key.self).decode(Repo.self, forKey: .repository)
            thread = try GitHubThread(from: decoder)
        }
        enum Key: String, CodingKey { case repository }
    }
    struct Out: Decodable { struct Search: Decodable { let nodes: [Hit] }; let search: Search }
    let scope = github.scope.isEmpty ? "involves:\(github.account)" : github.scope
    let day = since.formatted(.iso8601.year().month().day())
    let out: Out = try await gql(githubURL, auth: "bearer \(token)",
                                 "query($q: String!) { search(query: $q, type: ISSUE, first: 50) { nodes { ... on Issue { repository { nameWithOwner } } ... on PullRequest { repository { nameWithOwner } } \(githubThreadQuery) } } }",
                                 ["q": "\(scope) updated:>=\(day) sort:updated-desc"])
    let after = iso.string(from: since)
    return out.search.nodes.compactMap { hit in
        guard let repo = hit.repository?.nameWithOwner, let item = githubItem(hit.thread, repo: repo, since: after), !(item.text ?? "").isEmpty else { return nil }
        return indexed(item)
    }
}
