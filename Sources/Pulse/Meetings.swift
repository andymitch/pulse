import AVFoundation
import CoreAudio
import EventKit
import FluidAudio
import ScreenCaptureKit

struct Meeting: Codable {
    var title: String
    var start: Date
    var me: String
    var attendees: [String]
    var minutes: Int?
}

struct MeetingNotes: Codable {
    let title, summary: String
    let decisions, points: [String]
    let speakers: [String: String]?
}

@MainActor
final class Meetings: ObservableObject {
    static let shared = Meetings()
    @Published private(set) var recording: Meeting?
    @Published private(set) var transcribing = false
    @Published private(set) var saved: [SavedMeeting] = []
    @Published var error: String?
    private var capture: Capture?
    private var quietPolls = 0
    private var dismissed = false
    private var askedScreen = false
    private var askedCalendar = false
    private var me: () -> String? = { nil }
    private let calendar = EKEventStore()
    private let recordings = Settings.dir.appendingPathComponent("recordings")
    private let archive = Settings.dir.appendingPathComponent("meetings")

    func watch(me: @escaping () -> String?) {
        guard !demoMode else { return }
        saved = savedMeetings(in: archive)
        self.me = me
        Task { await processPending() }
        Task {
            while true {
                await poll()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop(skip: Bool = false) async {
        guard let capture, var meeting = recording else { return }
        dismissed = skip
        self.capture = nil
        recording = nil
        await capture.stop()
        meeting.minutes = Int(Date().timeIntervalSince(meeting.start) / 60)
        try? JSONEncoder().encode(meeting).write(to: capture.folder.appendingPathComponent("meeting.json"))
        Task { await processPending() }
    }

    private func poll() async {
        let users = micUsers()
        if users.isEmpty { dismissed = false }
        if recording != nil {
            quietPolls = users.isEmpty ? quietPolls + 1 : 0
            if quietPolls >= 6 || !settings.meetings.contains(.record) { await stop() }
        } else if settings.meetings.contains(.record), !dismissed, !users.isEmpty, let meeting = await detect(users) {
            await start(meeting)
        }
    }

    private func detect(_ micUsers: [String]) async -> Meeting? {
        let event = await currentEvent()
        var call: String?
        if micUsers.contains(where: { $0.hasPrefix("com.tinyspeck.slackmacgap") }) {
            call = "Slack huddle"
        } else if event == nil, canCaptureScreen() {
            let titles = (try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false))?.windows.compactMap(\.title) ?? []
            if titles.contains(where: { $0.hasPrefix("Meet - ") || $0.hasPrefix("Meet – ") }) { call = "Google Meet" }
        }
        guard let title = event?.title ?? call else { return nil }
        let people = event?.attendees ?? []
        return Meeting(title: title, start: Date(),
                       me: me() ?? people.first(where: \.isCurrentUser)?.name ?? "Me",
                       attendees: people.filter { !$0.isCurrentUser }.map { $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") })
    }

    private func canCaptureScreen() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if !askedScreen {
            askedScreen = true
            CGRequestScreenCaptureAccess()
        }
        return false
    }

    private func currentEvent() async -> EKEvent? {
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined, !askedCalendar {
            askedCalendar = true
            _ = try? await calendar.requestFullAccessToEvents()
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let now = Date()
        let soon = now.addingTimeInterval(600)
        return calendar.events(matching: calendar.predicateForEvents(withStart: now.addingTimeInterval(-86400), end: soon, calendars: nil))
            .filter { !$0.isAllDay && $0.startDate <= soon && $0.endDate > now && ($0.attendees?.count ?? 0) > 1 }
            .min { abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now)) }
    }

    private func start(_ meeting: Meeting) async {
        let folder = recordings.appendingPathComponent(String(Int(meeting.start.timeIntervalSince1970)))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(meeting).write(to: folder.appendingPathComponent("meeting.json"))
            capture = try await Capture(folder: folder, mic: await AVCaptureDevice.requestAccess(for: .audio))
            recording = meeting
            quietPolls = 0
            error = nil
        } catch {
            try? FileManager.default.removeItem(at: folder)
            dismissed = true
            self.error = "Couldn't record \(meeting.title): \(error.localizedDescription) Allow Pulse in System Settings > Privacy & Security > Screen & System Audio Recording."
        }
    }

    private func processPending() async {
        guard !transcribing else { return }
        transcribing = true
        var failed: Set<URL> = []
        while let folder = pending().first(where: { !failed.contains($0) }) {
            do {
                try await process(folder)
            } catch {
                failed.insert(folder)
                self.error = "Couldn't transcribe a meeting: \(error.localizedDescription) Pulse tries again after the next meeting."
            }
        }
        transcribing = false
        saved = savedMeetings(in: archive)
    }

    private func pending() -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: recordings, includingPropertiesForKeys: nil)) ?? []
        return folders.filter { $0.lastPathComponent != capture?.folder.lastPathComponent }.sorted { $0.path < $1.path }
    }

    private func process(_ folder: URL) async throws {
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: folder.appendingPathComponent("meeting.json")))
        let file = folder.appendingPathComponent("transcript.txt")
        if !FileManager.default.fileExists(atPath: file.path) {
            try await transcribeMeeting(folder, me: meeting.me, attendees: meeting.attendees).write(to: file, atomically: true, encoding: .utf8)
        }
        var transcript = try String(contentsOf: file, encoding: .utf8)
        if !transcript.isEmpty {
            let notes = await summarize(meeting, transcript: file, folder: folder)
            for (label, name) in notes?.speakers ?? [:] { transcript = transcript.replacingOccurrences(of: "] \(label):", with: "] \(name):") }
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            try meetingMarkdown(meeting, notes: notes, transcript: transcript)
                .write(to: archive.appendingPathComponent(folder.lastPathComponent + ".md"), atomically: true, encoding: .utf8)
        }
        try FileManager.default.removeItem(at: folder)
    }

    private func summarize(_ meeting: Meeting, transcript: URL, folder: URL) async -> MeetingNotes? {
        let out = folder.appendingPathComponent("notes.json")
        let prompt = folder.appendingPathComponent("notes-prompt.md")
        do {
            try notesPrompt(meeting, transcript: transcript.path, output: out.path).write(to: prompt, atomically: true, encoding: .utf8)
            let log = try await runAgent(prompt: prompt)
            guard let data = try? Data(contentsOf: out) else { throw SyncError(description: "The agent did not write its file. Last output:\n\(log)") }
            return try JSONDecoder().decode(MeetingNotes.self, from: data)
        } catch {
            self.error = "Saved \(meeting.title) without a summary: \(error)"
            return nil
        }
    }
}

private final class Capture: NSObject, SCStreamOutput {
    let folder: URL
    private let stream: SCStream
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "pulse.meeting-audio")
    private var system: AVAudioFile?
    private var mic: AVAudioFile?

    init(folder: URL, mic micAllowed: Bool) async throws {
        self.folder = folder
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw SyncError(description: "There is no display to capture audio from.") }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 10, timescale: 1)
        stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
        super.init()
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()

        let format = engine.inputNode.outputFormat(forBus: 0)
        guard micAllowed, format.sampleRate > 0 else { return }
        mic = try? AVAudioFile(forWriting: folder.appendingPathComponent("mic.caf"), settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in try? self?.mic?.write(from: buffer) }
        try? engine.start()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let description = buffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        try? buffer.withAudioBufferList { list, _ in
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer) else { return }
            if system == nil {
                system = try AVAudioFile(forWriting: folder.appendingPathComponent("system.caf"), settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            }
            try system?.write(from: pcm)
        }
    }

    func stop() async {
        try? await stream.stopCapture()
        if mic != nil {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            mic = nil
        }
        queue.sync { system = nil }
    }
}

private func audioProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    _ = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
    return value
}

func micUsers() -> [String] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
    var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }
    return processes
        .filter { audioProperty($0, kAudioProcessPropertyIsRunningInput, UInt32(0)) != 0 && audioProperty($0, kAudioProcessPropertyPID, pid_t(0)) != getpid() }
        .map { audioProperty($0, kAudioProcessPropertyBundleID, "" as CFString) as String }
}

func transcribeMeeting(_ folder: URL, me: String, attendees: [String]) async throws -> String {
    let asr = AsrManager()
    try await asr.loadModels(try await AsrModels.downloadAndLoad())
    func words(_ name: String) async throws -> [WordTiming] {
        let url = folder.appendingPathComponent(name)
        guard let audio = try? AVAudioFile(forReading: url), Double(audio.length) > audio.fileFormat.sampleRate else { return [] }
        var state = TdtDecoderState.make()
        return buildWordTimings(from: try await asr.transcribe(url, decoderState: &state).tokenTimings ?? [])
    }
    let mine = try await words("mic.caf")
    let theirs = try await words("system.caf")
    var turns: [Turn] = []
    if !theirs.isEmpty && attendees.count != 1 {
        let diarizer = OfflineDiarizerManager()
        try await diarizer.prepareModels()
        turns = try await diarizer.process(folder.appendingPathComponent("system.caf")).segments
            .map { Turn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
    }
    return transcriptText(mine: mine, theirs: theirs, turns: turns, me: me, attendees: attendees)
}

struct Turn {
    let speaker: String
    let start, end: Double
}

func transcriptText(mine: [WordTiming], theirs: [WordTiming], turns: [Turn], me: String, attendees: [String]) -> String {
    let key = { (word: String) in word.lowercased().filter { $0.isLetter || $0.isNumber } }
    let echoes = Dictionary(grouping: theirs, by: { key($0.word) })
    let spoken = mine.filter { w in !(echoes[key(w.word)] ?? []).contains { abs($0.startTime - w.startTime) < 1 } }
    let ids = turns.map(\.speaker).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    func speaker(_ t: Double) -> String {
        if attendees.count == 1 { return attendees[0] }
        let gap = { (turn: Turn) in max(turn.start - t, t - turn.end, 0) }
        guard let turn = turns.min(by: { gap($0) < gap($1) }) else { return "Speaker 1" }
        return "Speaker \(ids.firstIndex(of: turn.speaker)! + 1)"
    }
    let words = (spoken.map { ($0.startTime, me, $0.word) } + theirs.map { ($0.startTime, speaker($0.startTime), $0.word) }).sorted { $0.0 < $1.0 }
    var lines: [String] = []
    var current = ""
    for (time, who, word) in words {
        if who == current {
            lines[lines.count - 1] += " " + word
        } else {
            lines.append(String(format: "[%d:%02d] %@: %@", Int(time) / 60, Int(time) % 60, who, word))
            current = who
        }
    }
    return lines.joined(separator: "\n")
}

func notesPrompt(_ m: Meeting, transcript: String, output: String) -> String {
    let attendees = m.attendees.isEmpty ? "" : " The other attendees were: \(m.attendees.joined(separator: ", "))."
    return """
    You are distilling a meeting that Pulse recorded on \(m.me)'s Mac: "\(m.title)", started \(m.start.formatted(date: .complete, time: .shortened)).\(attendees)

    Read the transcript in \(transcript). Each line is "[minutes:seconds] speaker: words". Lines from \(m.me) are labelled with that name; "Speaker N" are other people. Speech recognition makes mistakes, so read past odd words.

    This is read-only. Never post, comment, create, or change anything anywhere. Only write the file below.

    Write one JSON file to \(output) with exactly this shape and nothing else:
    {"title": string, "summary": string, "decisions": [string], "points": [string], "speakers": {"Speaker N": string}}

    Rules:
    - title: "\(m.title)" unchanged, unless it is a generic name like "Google Meet" or "Slack huddle"; then a short name for what was discussed.
    - summary: 2 to 4 plain sentences on what the meeting was about and where it landed.
    - decisions: the 1 to 5 most important things that were agreed or decided. Empty if nothing was decided.
    - points: the 1 to 5 most important other points, such as open questions, risks, and action items with the owner's name.
    - Each decision and point is one short line: the key part in bold, then the rest of the sentence, like "**Ship Friday** after QA signs off on the import fix".
    - speakers: name a "Speaker N" only when the transcript makes clear who it is, for example they are addressed by name or introduce themselves\(m.attendees.isEmpty ? "" : ", and only with one of the attendees"). Leave the rest out.
    - Write plainly. No hype, no filler.
    """
}

struct SavedMeeting: Identifiable {
    let file: URL
    let start: Date
    var title = "", recorded = "", summary = ""
    var decisions: [String] = [], points: [String] = []

    var id: URL { file }
}

func savedMeetings(in archive: URL, limit: Int = 10) -> [SavedMeeting] {
    ((try? FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "md" }
        .compactMap { file in TimeInterval(file.deletingPathExtension().lastPathComponent).map { (file, Date(timeIntervalSince1970: $0)) } }
        .sorted { $0.1 > $1.1 }
        .prefix(limit)
        .compactMap { file, start in (try? String(contentsOf: file, encoding: .utf8)).map { parseMeeting($0, file: file, start: start) } }
}

func parseMeeting(_ markdown: String, file: URL, start: Date) -> SavedMeeting {
    var m = SavedMeeting(file: file, start: start)
    var section = ""
    for line in markdown.split(separator: "\n").map(String.init) {
        if line.hasPrefix("## ") {
            section = String(line.dropFirst(3))
            if section == "Transcript" { break }
        } else if line.hasPrefix("# "), m.title.isEmpty {
            m.title = String(line.dropFirst(2))
        } else {
            let item = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
            switch section {
            case "": m.recorded = line
            case "Summary": m.summary += m.summary.isEmpty ? line : "\n" + line
            case "Decisions": m.decisions.append(item)
            case "Important points": m.points.append(item)
            default: break
            }
        }
    }
    return m
}

func meetingMarkdown(_ m: Meeting, notes: MeetingNotes?, transcript: String) -> String {
    var lines = ["# \(notes?.title ?? m.title)", ""]
    let length = m.minutes.map { " (\($0) min)" } ?? ""
    let with = m.attendees.isEmpty ? "" : ". With \(([m.me] + m.attendees).joined(separator: ", "))"
    lines.append("Recorded \(m.start.formatted(date: .abbreviated, time: .shortened))\(length)\(with).")
    if let notes {
        lines += ["", "## Summary", "", notes.summary]
        if !notes.decisions.isEmpty { lines += ["", "## Decisions", ""] + notes.decisions.prefix(5).map { "- " + $0 } }
        if !notes.points.isEmpty { lines += ["", "## Important points", ""] + notes.points.prefix(5).map { "- " + $0 } }
    }
    lines += ["", "## Transcript", "", transcript, ""]
    return lines.joined(separator: "\n")
}
