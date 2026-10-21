import AVFoundation
import FluidAudio
import SwiftUI

func markdown(_ text: String) -> AttributedString {
    var s = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    for run in s.runs where run.inlinePresentationIntent?.contains(.code) == true {
        s[run.range].inlinePresentationIntent = nil
        s[run.range].font = .system(.body, design: .monospaced).weight(.regular)
        s[run.range].backgroundColor = Color.primary.opacity(0.12)
    }
    return s
}

@MainActor
final class NaturalVoice: ObservableObject {
    static let shared = NaturalVoice()
    static let size = "243 MB"

    enum State: Equatable { case missing, downloading, ready, failed(String) }

    @Published var state: State
    @Published var progress = 0.0
    @Published var settingUp = false
    private var manager: Any?
    private static let expectedBytes = 243_000_000.0
    private let dir = Settings.dir.appendingPathComponent("Voice")
    private var marker: URL { dir.appendingPathComponent(".ready") }

    var supported: Bool { ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)) }

    private init() {
        state = FileManager.default.fileExists(atPath: dir.appendingPathComponent(".ready").path) ? .ready : .missing
    }

    func download() async {
        guard #available(macOS 15, *) else { return }
        state = .downloading
        progress = 0
        let watcher = Task { [dir] in
            while !Task.isCancelled {
                let bytes = Double(folderSize(dir))
                self.progress = min(bytes / Self.expectedBytes, 1)
                if self.progress >= 0.99 { self.settingUp = true }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        defer { watcher.cancel(); settingUp = false }
        do {
            _ = try await load()
            try Data().write(to: marker)
            state = .ready
        } catch {
            manager = nil
            state = .failed("\(error)")
        }
    }

    private func pruneSources() {
        guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return }
        let packages = files.compactMap { $0 as? URL }.filter { $0.pathExtension == "mlpackage" }
        for package in packages { try? FileManager.default.removeItem(at: package) }
    }

    func remove() {
        manager = nil
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/fluidaudio/Models/kokoro"))
        state = .missing
    }

    func speak(_ text: String) async throws -> Data {
        guard #available(macOS 15, *) else { throw SyncError(description: "The natural voice needs macOS 15") }
        return try await load().synthesize(text: text)
    }

    @available(macOS 15, *)
    private func load() async throws -> KokoroAneManager {
        if let manager = manager as? KokoroAneManager { return manager }
        if state == .ready { settingUp = true }
        defer { if state == .ready { settingUp = false } }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let kokoro = KokoroAneManager(directory: dir, version: .v3)
        try await kokoro.initialize()
        pruneSources()
        manager = kokoro
        return kokoro
    }
}

private func folderSize(_ url: URL) -> Int {
    let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
    return (files?.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } } ?? []).reduce(0, +)
}

@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = Speaker()
    @Published var speaking = false
    @Published var preparing = false
    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?

    private override init() {
        super.init()
        synth.delegate = self
    }

    func toggle(_ text: String) {
        if speaking {
            stop()
            return
        }
        let plain = String(markdown(text).characters)
        speaking = true
        preparing = true
        guard settings.naturalVoice, NaturalVoice.shared.state == .ready else { return system(plain) }
        task = Task {
            do {
                let wav = try await NaturalVoice.shared.speak(plain)
                guard speaking, !Task.isCancelled else { return }
                let player = try AVAudioPlayer(data: wav)
                player.delegate = self
                self.player = player
                player.play()
                preparing = false
            } catch {
                if speaking { system(plain) }
            }
        }
    }

    func stop() {
        guard speaking || preparing else { return }
        preparing = false
        task?.cancel()
        player?.stop()
        player = nil
        synth.stopSpeaking(at: .immediate)
        speaking = false
    }

    private func system(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == AVSpeechSynthesisVoice.currentLanguageCode() }
            .max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        synth.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        Task { @MainActor in self.preparing = false }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false; self.preparing = false }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully: Bool) {
        Task { @MainActor in self.speaking = false; self.player = nil }
    }
}
