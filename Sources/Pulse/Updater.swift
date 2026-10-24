import AppKit
import CryptoKit

struct Version: Comparable {
    let parts: [Int]
    let beta: Int?

    init?(_ text: String) {
        let t = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let split = t.split(separator: "-", maxSplits: 1)
        let nums = split[0].split(separator: ".").compactMap { Int($0) }
        guard !nums.isEmpty else { return nil }
        parts = nums + Array(repeating: 0, count: max(0, 3 - nums.count))
        beta = split.count > 1 ? Int(split[1].split(separator: ".").last ?? "") ?? 0 : nil
    }

    static func < (a: Version, b: Version) -> Bool {
        if a.parts != b.parts { return a.parts.lexicographicallyPrecedes(b.parts) }
        switch (a.beta, b.beta) {
        case let (x?, y?): return x < y
        case (_?, nil): return true
        default: return false
        }
    }
}

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "andymitch/pulse"
    static let publicKey = "2hbTEWLRHLCRb1g3xymKTCsmq+ui6LC0/wtpQ8ZRdpQ="

    struct Release: Decodable {
        struct Asset: Decodable { let name, url, browser_download_url: String }
        let tag_name: String
        let prerelease, draft: Bool
        let assets: [Asset]
    }

    @Published var available: Release?
    @Published var installing = false
    @Published var error: String?
    private var checked = Date.distantPast

    var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var devBuild: Bool { current.hasSuffix("-dev") }

    func checkIfDue(every interval: TimeInterval = 12 * 3600) {
        guard !demoMode, Date().timeIntervalSince(checked) > interval else { return }
        Task { await check() }
    }

    func check() async {
        checked = Date()
        guard !devBuild else { return }
        guard let releases: [Release] = try? await fetch("https://api.github.com/repos/\(Self.repo)/releases?per_page=20"),
              let mine = Version(current) else { return }
        available = releases
            .filter { !$0.draft && (settings.betaUpdates || !$0.prerelease) && $0.assets.contains { $0.name == "Pulse_aarch64.zip" } }
            .compactMap { r in Version(r.tag_name).map { (r, $0) } }
            .filter { $0.1 > mine }
            .max { $0.1 < $1.1 }?.0
    }

    func install() async {
        guard let release = available,
              let zip = release.assets.first(where: { $0.name == "Pulse_aarch64.zip" }),
              let sig = release.assets.first(where: { $0.name == "Pulse_aarch64.zip.sig" }) else {
            error = "This release has no signed update."
            return
        }
        installing = true
        error = nil
        do {
            let archive = try await download(zip)
            let signature = try await download(sig)
            guard let key = Data(base64Encoded: Self.publicKey),
                  let raw = Data(base64Encoded: String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
                  try Curve25519.Signing.PublicKey(rawRepresentation: key).isValidSignature(raw, for: archive) else {
                throw SyncError(description: "The update's signature didn't match, so it wasn't installed.")
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("Pulse.zip")
            try archive.write(to: file)
            try shell("ditto -x -k \(quoted(file.path)) \(quoted(dir.path))")
            let fresh = dir.appendingPathComponent("Pulse.app")
            guard Bundle(url: fresh)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw SyncError(description: "The update didn't contain Pulse.")
            }
            let target = Bundle.main.bundleURL
            _ = try FileManager.default.replaceItemAt(target, withItemAt: fresh)
            try shell("xattr -dr com.apple.quarantine \(quoted(target.path)) 2>/dev/null || true")
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1; open \(quoted(target.path))"]
            try relaunch.run()
            NSApp.terminate(nil)
        } catch {
            self.error = "\(error)"
            installing = false
        }
    }

    private var tokens: [String] {
        ghAccounts().compactMap { try? shell("gh auth token -u \(quoted($0))").trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func fetch<T: Decodable>(_ url: String) async throws -> T {
        for token in [nil] + tokens.map(Optional.some) {
            var req = URLRequest(url: URL(string: url)!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, resp) = try await URLSession.shared.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 200 { return try JSONDecoder().decode(T.self, from: data) }
        }
        throw SyncError(description: "Couldn't reach \(Self.repo) releases.")
    }

    private func download(_ asset: Release.Asset) async throws -> Data {
        for token in [nil] + tokens.map(Optional.some) {
            var req = URLRequest(url: URL(string: token == nil ? asset.browser_download_url : asset.url)!)
            if let token {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            }
            let (data, resp) = try await URLSession.shared.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 200 { return data }
        }
        throw SyncError(description: "Couldn't download \(asset.name).")
    }
}
