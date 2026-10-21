import Foundation
import Security

let githubURL = URL(string: "https://api.github.com/graphql")!
let linearURL = URL(string: "https://api.linear.app/graphql")!

private let reposQuery = "query($org: String!) { organization(login: $org) { repositories(first: 100, orderBy: {field: PUSHED_AT, direction: DESC}) { nodes { name pushedAt isArchived } } membersWithRole(first: 100) { nodes { login name } } } }"
private let prsQuery = "query($owner: String!, $name: String!, $after: String) { repository(owner: $owner, name: $name) { pullRequests(states: MERGED, first: 100, after: $after, orderBy: {field: UPDATED_AT, direction: DESC}) { pageInfo { hasNextPage endCursor } nodes { number createdAt mergedAt updatedAt additions author { __typename login } } } } }"
private let issuesQuery = "query($after: String, $since: DateTimeOrDuration) { issues(first: 100, after: $after, includeArchived: true, orderBy: updatedAt, filter: {updatedAt: {gt: $since}}) { pageInfo { hasNextPage endCursor } nodes { id identifier title url createdAt completedAt creator { name } assignee { name } } } }"

struct SyncError: Error, CustomStringConvertible {
    let description: String
}

private struct Response<T: Decodable>: Decodable {
    struct Message: Decodable { let message: String }
    let data: T?
    let errors: [Message]?
}

private struct PageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
}

private struct Page<T: Decodable>: Decodable {
    let pageInfo: PageInfo
    let nodes: [T]
}

struct Nodes<T: Decodable>: Decodable {
    let nodes: [T]
}

struct Named: Decodable {
    let name: String
}

private struct ReposData: Decodable {
    struct Member: Decodable { let login: String; let name: String? }
    struct Org: Decodable { let repositories: Nodes<Repo>; let membersWithRole: Nodes<Member> }
    struct Repo: Decodable { let name: String; let pushedAt: String?; let isArchived: Bool }
    let organization: Org
}

private struct PRsData: Decodable {
    struct Repo: Decodable { let pullRequests: Page<PR> }
    struct PR: Decodable {
        struct Author: Decodable { let __typename: String; let login: String }
        let number: Int
        let createdAt: String
        let mergedAt: String
        let updatedAt: String
        let additions: Int
        let author: Author?
    }
    let repository: Repo
}

private struct IssuesData: Decodable {
    struct Issue: Decodable {
        let id, identifier, title, url, createdAt: String
        let completedAt: String?
        let creator, assignee: Named?
    }
    let issues: Page<Issue>
}

func gql<T: Decodable>(_ url: URL, auth: String, _ query: String, _ variables: [String: Any] = [:]) async throws -> T {
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue(auth, forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
    let (data, resp) = try await URLSession.shared.data(for: req)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard let decoded = try? JSONDecoder().decode(Response<T>.self, from: data) else {
        throw SyncError(description: "\(url.host ?? "") HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
    }
    if let errors = decoded.errors, !errors.isEmpty {
        throw SyncError(description: "\(url.host ?? ""): " + errors.map(\.message).joined(separator: "; "))
    }
    guard let result = decoded.data else { throw SyncError(description: "\(url.host ?? ""): empty response") }
    return result
}

let iso = ISO8601DateFormatter()

private func window(_ db: DB, _ key: String) -> (since: String, start: String) {
    (db.meta(key) ?? iso.string(from: Date().addingTimeInterval(-365 * 86400)), iso.string(from: Date()))
}

func ghAccounts() -> [String] {
    struct Status: Decodable { struct Account: Decodable { let login: String; let active: Bool }; let hosts: [String: [Account]] }
    guard let out = try? shell("gh auth status --json hosts 2>/dev/null"),
          let status = try? JSONDecoder().decode(Status.self, from: Data(out.utf8)) else { return [] }
    return (status.hosts["github.com"] ?? []).sorted { $0.active && !$1.active }.map(\.login)
}

func ghOrgs(account: String) -> [String] {
    let out = (try? shell("GH_TOKEN=$(gh auth token -u \(quoted(account))) gh api user/orgs --jq '.[].login'")) ?? ""
    return out.split(separator: "\n").map(String.init)
}

func ghToken() throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", settings.githubAccount.isEmpty ? "gh auth token" : "gh auth token -u \(quoted(settings.githubAccount))"]
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    try p.run()
    p.waitUntilExit()
    let token = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard p.terminationStatus == 0, !token.isEmpty else {
        throw SyncError(description: "gh auth token failed: " + String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
    return token
}

private let keychainQuery: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "pulse",
    kSecAttrAccount as String: "linear",
]

func linearKey() -> String? {
    var query = keychainQuery
    query[kSecReturnData as String] = true
    var out: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
    return String(data: data, encoding: .utf8)
}

func removeLinearKey() {
    SecItemDelete(keychainQuery as CFDictionary)
}

func saveLinearKey(_ key: String) async throws {
    struct Viewer: Decodable { struct V: Decodable { let id: String }; let viewer: V }
    let _: Viewer = try await gql(linearURL, auth: key, "{ viewer { id } }")
    let data = Data(key.utf8)
    var status = SecItemUpdate(keychainQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
        var add = keychainQuery
        add[kSecValueData as String] = data
        status = SecItemAdd(add as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw SyncError(description: "Keychain error \(status)") }
}

func syncGitHub(_ db: DB, token: String) async throws {
    let auth = "bearer \(token)"
    let (since, start) = window(db, "github_since")
    guard !settings.githubOrg.isEmpty else { return }
    let org = settings.githubOrg
    let repos: ReposData = try await gql(githubURL, auth: auth, reposQuery, ["org": org])
    try db.transaction {
        for m in repos.organization.membersWithRole.nodes {
            try db.query("INSERT OR REPLACE INTO github_users VALUES (?, ?)", [m.login, m.name])
        }
    }
    for repo in repos.organization.repositories.nodes where !repo.isArchived && (repo.pushedAt ?? "") >= since {
        var after: String?
        while true {
            let page: PRsData = try await gql(githubURL, auth: auth, prsQuery, ["owner": org, "name": repo.name, "after": after ?? NSNull()])
            let prs = page.repository.pullRequests
            let fresh = prs.nodes.prefix { $0.updatedAt >= since }
            try db.transaction {
                for pr in fresh where pr.author?.__typename != "Bot" {
                    try db.query("INSERT OR REPLACE INTO prs VALUES (?, ?, ?, ?, ?, ?)",
                                 [repo.name, pr.number, pr.author?.login ?? "ghost", pr.createdAt, pr.mergedAt, pr.additions])
                }
            }
            guard fresh.count == prs.nodes.count, prs.pageInfo.hasNextPage else { break }
            after = prs.pageInfo.endCursor
        }
    }
    try db.setMeta("github_since", start)
}

private struct UsersData: Decodable {
    struct User: Decodable { let name, email: String }
    struct Org: Decodable { let urlKey: String }
    let viewer: User
    let users: Nodes<User>
    let organization: Org
}

func syncLinear(_ db: DB, key: String) async throws {
    let people: UsersData = try await gql(linearURL, auth: key, "{ viewer { name email } organization { urlKey } users(first: 250, includeDisabled: true) { nodes { name email } } }")
    try db.transaction {
        try db.query("DELETE FROM users")
        for u in people.users.nodes where !u.email.hasSuffix(".linear.app") {
            try db.query("INSERT OR REPLACE INTO users VALUES (?, ?)", [u.name, u.email])
        }
        try db.setMeta("me", displayName(people.viewer.name))
        try db.setMeta("linear_workspace", people.organization.urlKey)
    }
    let (since, start) = window(db, "linear_since")
    var after: String?
    while true {
        let page: IssuesData = try await gql(linearURL, auth: key, issuesQuery, ["after": after ?? NSNull(), "since": since])
        try db.transaction {
            for i in page.issues.nodes {
                try db.query("INSERT OR REPLACE INTO issues VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                             [i.id, i.identifier, i.title, i.url, i.creator?.name, i.assignee?.name, i.createdAt, i.completedAt])
            }
        }
        guard page.issues.pageInfo.hasNextPage else { break }
        after = page.issues.pageInfo.endCursor
    }
    try db.setMeta("linear_since", start)
}
