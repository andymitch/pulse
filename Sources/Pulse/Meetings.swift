import AVFoundation
import CoreAudio
import EventKit
import FluidAudio
import IOKit.pwr_mgt
import ScreenCaptureKit
import UserNotifications

struct Meeting: Codable {
    var title: String
    var start: Date
    var me: String
    var attendees: [String]
    var minutes: Int?
    var marks: [Double]?
    var end: Date?
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
    @Published private(set) var noAudio = false
    @Published private(set) var saved: [SavedMeeting] = []
    @Published private(set) var summarizing: Set<URL> = []
    @Published var error: String?
    var shown: Bool { settings.connections.recordsMeetings || !saved.isEmpty }

    func reload() {
        guard !demoMode else { return }
        saved = savedMeetings(in: archive)
    }
    private var capture: Capture?
    private var quietPolls = 0
    private var dismissed = false
    private var manual = false
    private var starting = false
    private var askedScreen = false
    private var askedCalendar = false
    private var me: () -> String? = { nil }
    private var asking: Meeting?
    private let asker = Asker()
    private let calendar = EKEventStore()
    private var archive: URL { project.dir.appendingPathComponent("meetings") }

    func watch(me: @escaping () -> String?) {
        guard !demoMode else { saved = demoMeetings; return }
        saved = savedMeetings(in: archive)
        self.me = me
        UNUserNotificationCenter.current().delegate = asker
        processSoon()
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
        manual = false
        self.capture = nil
        recording = nil
        noAudio = false
        await capture.stop()
        meeting.end = Date()
        meeting.minutes = Int(meeting.end!.timeIntervalSince(meeting.start) / 60)
        try? JSONEncoder().encode(meeting).write(to: capture.folder.appendingPathComponent("meeting.json"))
        processSoon()
    }

    private func processSoon() {
        Task {
            try? await Task.sleep(for: .seconds(restartGap))
            await processPending()
        }
    }

    func mark() {
        guard let capture, var meeting = recording else { return }
        meeting.marks = (meeting.marks ?? []) + [Date().timeIntervalSince(meeting.start)]
        recording = meeting
        try? JSONEncoder().encode(meeting).write(to: capture.folder.appendingPathComponent("meeting.json"))
    }

    private func poll() async {
        let users = micUsers()
        if users.isEmpty {
            dismissed = false
            asking = nil
        }
        if let capture {
            await capture.heal()
            noAudio = capture.silent
        }
        if recording != nil {
            var live = manual || !users.isEmpty
            if !live { live = await meetOpen() }
            quietPolls = live ? 0 : quietPolls + 1
            if quietPolls >= 6 { await stop() }
        } else if !dismissed, asking == nil, !users.isEmpty {
            let projects = Project.all(in: Settings.dir).map { ($0, $0.connections) }
            guard projects.contains(where: { $0.1.recordsMeetings }), let (meeting, call) = await detect(users) else { return }
            let ids = claimants(call, in: projects.map { ($0.0.id, $0.1) })
            if ids.count == 1, let p = projects.first(where: { $0.0.id == ids[0] }) {
                await start(meeting, in: p.0)
            } else if ids.count > 1 {
                ask(meeting, projects.map(\.0).filter { ids.contains($0.id) })
            }
        }
    }

    func startManually() async {
        guard recording == nil else { return }
        let event = await currentEvent()
        await start(meeting(event?.title ?? "Meeting", event), in: project, manual: true)
    }

    private func detect(_ micUsers: [String]) async -> (Meeting, Call)? {
        let event = await currentEvent()
        guard let call = callName(micUsers: micUsers, event: event != nil, meetOpen: await meetOpen()) else { return nil }
        let kind: Call = call == "Slack huddle" ? .slack(workspace: await slackWorkspace()) : .calendar(account: event?.calendar.source.title)
        return (meeting(event?.title ?? call, event), kind)
    }

    private func slackWorkspace() async -> String? {
        let all = slackWorkspaces()
        if all.count == 1 { return all.first?.domain }
        let titles = (try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false))?.windows
            .filter { $0.owningApplication?.bundleIdentifier.hasPrefix("com.tinyspeck.slackmacgap") == true }.compactMap(\.title) ?? []
        return all.first { w in titles.contains { $0.contains(" - \(w.name) - ") || $0.hasSuffix(" - \(w.name)") } }?.domain
    }

    private func ask(_ meeting: Meeting, _ projects: [Project]) {
        asking = meeting
        let center = UNUserNotificationCenter.current()
        let actions = projects.map { UNNotificationAction(identifier: $0.id, title: "Record for \($0.name)") } + [UNNotificationAction(identifier: "skip", title: "Don't record")]
        center.setNotificationCategories([UNNotificationCategory(identifier: "meeting", actions: actions, intentIdentifiers: [])])
        let content = UNMutableNotificationContent()
        content.title = "Record \(meeting.title)?"
        content.body = "Pulse can't tell which project this call is for."
        content.categoryIdentifier = "meeting"
        Task {
            _ = try? await center.requestAuthorization(options: [.alert])
            try? await center.add(UNNotificationRequest(identifier: "meeting", content: content, trigger: nil))
        }
    }

    fileprivate func answer(_ action: String) async {
        guard let meeting = asking else { return }
        asking = nil
        if let p = Project.named(action, in: Settings.dir) { await start(meeting, in: p) } else { dismissed = true }
    }

    private func meetOpen() async -> Bool {
        guard canCaptureScreen() else { return false }
        let titles = (try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false))?.windows.compactMap(\.title) ?? []
        return titles.contains { $0.hasPrefix("Meet - ") || $0.hasPrefix("Meet – ") }
    }

    private func meeting(_ title: String, _ event: EKEvent?) -> Meeting {
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

    private func start(_ meeting: Meeting, in target: Project, manual: Bool = false) async {
        guard !starting, recording == nil else { return }
        starting = true
        defer { starting = false }
        let folder = target.dir.appendingPathComponent("recordings").appendingPathComponent(String(Int(meeting.start.timeIntervalSince1970)))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(meeting).write(to: folder.appendingPathComponent("meeting.json"))
            capture = try await Capture(folder: folder, mic: await AVCaptureDevice.requestAccess(for: .audio))
            recording = meeting
            self.manual = manual
            quietPolls = 0
            error = nil
        } catch {
            try? FileManager.default.removeItem(at: folder)
            dismissed = true
            self.error = "Couldn't record \(meeting.title): \(error.localizedDescription) Allow Pulse in System Settings > Privacy & Security > Screen & System Audio Recording."
        }
    }

    func delete(_ meeting: SavedMeeting) {
        do {
            try FileManager.default.trashItem(at: meeting.file, resultingItemURL: nil)
            error = nil
        } catch {
            self.error = "Couldn't delete \(meeting.title): \(error.localizedDescription)"
        }
        saved = savedMeetings(in: archive)
    }

    private func processPending() async {
        guard !transcribing else { return }
        transcribing = true
        var failed: Set<URL> = []
        while let group = pending().first(where: { !failed.contains($0[0]) }) {
            do {
                try await process(group)
            } catch {
                failed.insert(group[0])
                self.error = "Couldn't transcribe a meeting: \(error.localizedDescription) Pulse tries again after the next meeting."
            }
        }
        transcribing = false
        saved = savedMeetings(in: archive)
    }

    private func pending() -> [[URL]] {
        let folders = Project.all(in: Settings.dir).flatMap { p in
            (try? FileManager.default.contentsOfDirectory(at: p.dir.appendingPathComponent("recordings"), includingPropertiesForKeys: nil)) ?? []
        }
        let stopped = folders.filter { $0.lastPathComponent != capture?.folder.lastPathComponent }
            .map { ($0, try? JSONDecoder().decode(Meeting.self, from: Data(contentsOf: $0.appendingPathComponent("meeting.json")))) }
        return captureGroups(stopped, now: Date(), recording: recording?.start)
    }

    private func process(_ folders: [URL]) async throws {
        let parts = try folders.map { try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: $0.appendingPathComponent("meeting.json"))) }
        var meeting = parts[parts.count - 1]
        meeting.start = parts[0].start
        let offsets = parts.map { $0.start.timeIntervalSince(meeting.start) }
        meeting.marks = zip(parts, offsets).flatMap { part, offset in (part.marks ?? []).map { $0 + offset } }
        if let end = meeting.end { meeting.minutes = Int(end.timeIntervalSince(meeting.start) / 60) }
        let folder = folders[0]
        let file = folder.appendingPathComponent("transcript.txt")
        if !FileManager.default.fileExists(atPath: file.path) {
            try await transcribeMeeting(Array(zip(folders, offsets)), me: meeting.me, attendees: meeting.attendees, marks: meeting.marks ?? []).write(to: file, atomically: true, encoding: .utf8)
        }
        var transcript = try String(contentsOf: file, encoding: .utf8)
        if spokenWords(transcript) > 0 {
            var notes: MeetingNotes?
            if spokenWords(transcript) >= 30 {
                do { notes = try await summarize(meeting, transcript: file, folder: folder) } catch { self.error = "Saved \(meeting.title) without a summary: \(error)" }
            }
            for (label, name) in notes?.speakers ?? [:] { transcript = transcript.replacingOccurrences(of: "] \(label):", with: "] \(name):") }
            let meetings = folder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("meetings")
            try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
            try meetingMarkdown(meeting, notes: notes, transcript: transcript)
                .write(to: meetings.appendingPathComponent(folder.lastPathComponent + ".md"), atomically: true, encoding: .utf8)
        }
        for folder in folders.reversed() { try FileManager.default.removeItem(at: folder) }
    }

    private func summarize(_ meeting: Meeting, transcript: URL, folder: URL) async throws -> MeetingNotes {
        let out = folder.appendingPathComponent("notes.json")
        let prompt = folder.appendingPathComponent("notes-prompt.md")
        try notesPrompt(meeting, transcript: transcript.path, output: out.path).write(to: prompt, atomically: true, encoding: .utf8)
        var log = ""
        for _ in 1...2 {
            try? FileManager.default.removeItem(at: out)
            do { log = try await runAgent(prompt: prompt) } catch { log = "\(error)" }
            if let data = try? Data(contentsOf: out), let notes = try? JSONDecoder().decode(MeetingNotes.self, from: data) { return notes }
        }
        throw SyncError(description: "The agent did not write its notes. Last output:\n\(log)")
    }

    func summarize(_ saved: SavedMeeting) async {
        guard !summarizing.contains(saved.id), let markdown = try? String(contentsOf: saved.file, encoding: .utf8),
              let split = markdown.range(of: "\n## Transcript\n") else { return }
        summarizing.insert(saved.id)
        defer { summarizing.remove(saved.id) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let people = saved.people
        let meeting = Meeting(title: saved.title, start: saved.start, me: people.first ?? me() ?? "Me", attendees: Array(people.dropFirst()))
        let transcript = folder.appendingPathComponent("transcript.txt")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try String(markdown[split.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines).write(to: transcript, atomically: true, encoding: .utf8)
            let notes = try await summarize(meeting, transcript: transcript, folder: folder)
            guard var updated = editMeeting(markdown, title: notes.title, summary: notes.summary, decisions: Array(notes.decisions.prefix(5)), points: Array(notes.points.prefix(5))) else {
                throw SyncError(description: "its notes have sections Pulse doesn't know.")
            }
            for (label, name) in notes.speakers ?? [:] { updated = updated.replacingOccurrences(of: "] \(label):", with: "] \(name):") }
            try updated.write(to: saved.file, atomically: true, encoding: .utf8)
            error = nil
        } catch {
            self.error = "Couldn't summarize \(saved.title): \(error)"
        }
        self.saved = savedMeetings(in: archive)
    }
}

private final class Capture: NSObject, SCStreamOutput {
    let folder: URL
    private var stream: SCStream?
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "pulse.meeting-audio")
    private let begun = Date()
    private var system: AVAudioFile?
    private var mic: AVAudioFile?
    private var lastSystem = Date()
    private var lastMic = Date()
    private var awake: IOPMAssertionID = 0

    init(folder: URL, mic micAllowed: Bool) async throws {
        self.folder = folder
        super.init()
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Recording a meeting" as CFString, &awake)
        try await startSystem()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard micAllowed, format.sampleRate > 0 else { return }
        mic = try? AVAudioFile(forWriting: folder.appendingPathComponent("mic.caf"), settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        startMic()
    }

    private func startSystem() async throws {
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
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        queue.sync { lastSystem = Date() }
    }

    private func startMic() {
        guard let file = mic else { return }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        let converter = format == file.processingFormat ? nil : AVAudioConverter(from: format, to: file.processingFormat)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let file = self.mic, let buffer = converter.map({ convert(buffer, with: $0) }) ?? buffer else { return }
            try? append(buffer, to: file, since: self.begun)
            self.queue.async { self.lastMic = Date() }
        }
        try? engine.start()
    }

    var silent: Bool {
        queue.sync { Date().timeIntervalSince(mic == nil ? lastSystem : min(lastSystem, lastMic)) > 15 }
    }

    func heal() async {
        if mic != nil, !engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            startMic()
        }
        if queue.sync(execute: { Date().timeIntervalSince(lastSystem) }) > 15 {
            try? await stream?.stopCapture()
            try? await startSystem()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let description = buffer.formatDescription else { return }
        lastSystem = Date()
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        try? buffer.withAudioBufferList { list, _ in
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer) else { return }
            if system == nil {
                system = try AVAudioFile(forWriting: folder.appendingPathComponent("system.caf"), settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            }
            if let system { try append(pcm, to: system, since: begun) }
        }
    }

    deinit { IOPMAssertionRelease(awake) }

    func stop() async {
        try? await stream?.stopCapture()
        if mic != nil {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            mic = nil
        }
        queue.sync { system = nil }
    }
}

let markLine = "★ Marked as important"

func spokenWords(_ transcript: String) -> Int {
    transcript.split(separator: "\n").filter { !$0.hasSuffix(markLine) }.map { $0.split(separator: ":", maxSplits: 2).last ?? "" }.reduce(0) { $0 + $1.split(separator: " ").count }
}

func append(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile, since start: Date) throws {
    let rate = file.processingFormat.sampleRate
    var gap = AVAudioFramePosition(Date().timeIntervalSince(start) * rate) - AVAudioFramePosition(buffer.frameLength) - file.length
    if gap > AVAudioFramePosition(rate) {
        while gap > 0, let silence = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(min(gap, AVAudioFramePosition(rate)))) {
            silence.frameLength = silence.frameCapacity
            for channel in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) { memset(channel.mData, 0, Int(channel.mDataByteSize)) }
            try file.write(from: silence)
            gap -= AVAudioFramePosition(silence.frameLength)
        }
    }
    try file.write(from: buffer)
}

func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * converter.outputFormat.sampleRate / buffer.format.sampleRate) + 1
    guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return nil }
    var given = false
    let status = converter.convert(to: out, error: nil) { _, input in
        input.pointee = given ? .noDataNow : .haveData
        defer { given = true }
        return given ? nil : buffer
    }
    return status == .error ? nil : out
}

private func audioProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    _ = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
    return value
}

private let callApps = ["us.zoom.xos", "com.microsoft.teams", "com.apple.FaceTime", "com.cisco.webex", "com.google.Chrome", "com.apple.Safari",
                        "company.thebrowser.", "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser"]

func callName(micUsers: [String], event: Bool, meetOpen: Bool) -> String? {
    if micUsers.contains(where: { $0.hasPrefix("com.tinyspeck.slackmacgap") }) { return "Slack huddle" }
    guard micUsers.contains(where: { user in callApps.contains { user.hasPrefix($0) } }) else { return nil }
    return meetOpen ? "Google Meet" : event ? "Call" : nil
}

let restartGap: TimeInterval = 120

func captureGroups(_ stopped: [(folder: URL, meeting: Meeting?)], now: Date, recording: Date?) -> [[URL]] {
    var groups: [[(folder: URL, meeting: Meeting?)]] = []
    for capture in stopped.sorted(by: { $0.folder.path < $1.folder.path }) {
        if let last = groups.last?.last, last.folder.deletingLastPathComponent() == capture.folder.deletingLastPathComponent(),
           let end = last.meeting?.end, let start = capture.meeting?.start, start.timeIntervalSince(end) < restartGap {
            groups[groups.count - 1].append(capture)
        } else {
            groups.append([capture])
        }
    }
    return groups.filter { group in
        guard let end = group.last?.meeting?.end else { return true }
        return now.timeIntervalSince(end) >= restartGap && (recording.map { $0.timeIntervalSince(end) >= restartGap } ?? true)
    }.map { $0.map(\.folder) }
}

enum Call: Equatable { case slack(workspace: String?), calendar(account: String?) }

func claimants(_ call: Call, in projects: [(id: String, connections: Connections)]) -> [String] {
    let pick = { (on: [(id: String, connections: Connections)], named: String?, key: (Connections) -> String) -> [String] in
        guard let named else { return on.map(\.id) }
        let exact = on.filter { key($0.connections).caseInsensitiveCompare(named) == .orderedSame }
        return (exact.isEmpty ? on.filter { key($0.connections).isEmpty } : exact).map(\.id)
    }
    switch call {
    case .slack(let workspace): return pick(projects.filter { $0.connections.slack?.meetings == true }, workspace) { $0.slack?.workspace ?? "" }
    case .calendar(let account): return pick(projects.filter { $0.connections.google?.meetings == true }, account) { $0.google?.account ?? "" }
    }
}

func slackWorkspaces(state: URL = slackState) -> [(domain: String, name: String)] {
    let root = (try? JSONSerialization.jsonObject(with: Data(contentsOf: state))) as? [String: Any]
    return ((root?["workspaces"] as? [String: [String: Any]]) ?? [:]).values
        .compactMap { w in (w["domain"] as? String).map { ($0, w["name"] as? String ?? $0) } }.sorted { $0.domain < $1.domain }
}

private final class Asker: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        await Meetings.shared.answer(action)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner] }
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
        .filter { $0 != "com.apple.replayd" }
}

func transcribeMeeting(_ parts: [(folder: URL, offset: Double)], me: String, attendees: [String], marks: [Double]) async throws -> String {
    let asr = AsrManager()
    try await asr.loadModels(try await AsrModels.downloadAndLoad())
    var mine: [WordTiming] = [], theirs: [WordTiming] = [], turns: [Turn] = []
    for (i, (folder, offset)) in parts.enumerated() {
        func words(_ name: String) async throws -> [WordTiming] {
            let url = folder.appendingPathComponent(name)
            guard let audio = try? AVAudioFile(forReading: url), Double(audio.length) > audio.fileFormat.sampleRate else { return [] }
            var state = TdtDecoderState.make()
            return buildWordTimings(from: try await asr.transcribe(url, decoderState: &state).tokenTimings ?? [])
                .map { WordTiming(word: $0.word, startTime: $0.startTime + offset, endTime: $0.endTime + offset) }
        }
        mine += try await words("mic.caf")
        let heard = try await words("system.caf")
        theirs += heard
        if !heard.isEmpty && attendees.count != 1 {
            let diarizer = OfflineDiarizerManager()
            try await diarizer.prepareModels()
            turns += try await diarizer.process(folder.appendingPathComponent("system.caf")).segments
                .map { Turn(speaker: "\(i)-\($0.speakerId)", start: Double($0.startTimeSeconds) + offset, end: Double($0.endTimeSeconds) + offset) }
        }
    }
    return transcriptText(mine: mine, theirs: theirs, turns: turns, me: me, attendees: attendees, marks: marks)
}

struct Turn {
    let speaker: String
    let start, end: Double
}

func transcriptText(mine: [WordTiming], theirs: [WordTiming], turns: [Turn], me: String, attendees: [String], marks: [Double] = []) -> String {
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
    let words = (spoken.map { ($0.startTime, me, $0.word) } + theirs.map { ($0.startTime, speaker($0.startTime), $0.word) } + marks.map { ($0, "", markLine) }).sorted { $0.0 < $1.0 }
    var lines: [String] = []
    var current = ""
    for (time, who, word) in words {
        if who.isEmpty {
            lines.append(String(format: "[%d:%02d] %@", Int(time) / 60, Int(time) % 60, word))
            current = ""
        } else if who == current {
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

    Read the transcript in \(transcript). Each line is "[minutes:seconds] speaker: words". Lines from \(m.me) are labelled with that name; "Speaker N" are other people. Lines that say "\(markLine)" are moments \(m.me) marked while the meeting was happening. Speech recognition makes mistakes, so read past odd words.

    This is read-only. Never post, comment, create, or change anything anywhere. Only write the file below.

    Write one JSON file to \(output) with exactly this shape and nothing else:
    {"title": string, "summary": string, "decisions": [string], "points": [string], "speakers": {"Speaker N": string}}

    Rules:
    - title: "\(m.title)" unchanged, unless it is a generic name like "Google Meet" or "Slack huddle"; then a short name for what was discussed.
    - summary: 2 to 4 plain sentences on what the meeting was about and where it landed.
    - decisions: the 1 to 5 most important things that were agreed or decided. Empty if nothing was decided.
    - points: the 1 to 5 most important other points, such as open questions, risks, and action items with the owner's name.
    - Marked moments matter most: cover what was being said right at and just before each one in more detail, and make sure each one is in the summary, decisions or points.
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
    var people: [String] { recorded.components(separatedBy: ". With ").dropFirst().first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).components(separatedBy: ", ") } ?? [] }
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

func editMeeting(_ markdown: String, title: String?, summary: String?, decisions: [String]?, points: [String]?) -> String? {
    let parts = markdown.components(separatedBy: "\n## Transcript\n")
    let known: Set<String> = ["Summary", "Decisions", "Important points"]
    guard parts.count > 1, parts[0].split(separator: "\n").allSatisfy({ !$0.hasPrefix("## ") || known.contains(String($0.dropFirst(3))) }) else { return nil }
    var m = parseMeeting(markdown, file: URL(fileURLWithPath: "/"), start: Date())
    if let title { m.title = title }
    if let summary { m.summary = summary.split(separator: "\n", omittingEmptySubsequences: false).map { $0.drop { $0 == "#" || $0 == " " } }.joined(separator: "\n") }
    if let decisions { m.decisions = decisions }
    if let points { m.points = points }
    return notesLines(title: m.title, recorded: m.recorded, summary: m.summary.isEmpty ? nil : m.summary, decisions: m.decisions, points: m.points)
        .joined(separator: "\n") + "\n\n## Transcript\n" + parts.dropFirst().joined(separator: "\n## Transcript\n")
}

private func notesLines(title: String, recorded: String, summary: String?, decisions: [String], points: [String]) -> [String] {
    var lines = ["# \(title)", "", recorded]
    if let summary { lines += ["", "## Summary", "", summary] }
    if !decisions.isEmpty { lines += ["", "## Decisions", ""] + decisions.map { "- " + $0 } }
    if !points.isEmpty { lines += ["", "## Important points", ""] + points.map { "- " + $0 } }
    return lines
}

func meetingMarkdown(_ m: Meeting, notes: MeetingNotes?, transcript: String) -> String {
    let length = m.minutes.map { " (\($0) min)" } ?? ""
    let with = m.attendees.isEmpty ? "" : ". With \(([m.me] + m.attendees).joined(separator: ", "))"
    let recorded = "Recorded \(m.start.formatted(date: .abbreviated, time: .shortened))\(length)\(with)."
    let lines = notesLines(title: notes?.title ?? m.title, recorded: recorded, summary: notes?.summary,
                           decisions: Array((notes?.decisions ?? []).prefix(5)), points: Array((notes?.points ?? []).prefix(5)))
    return (lines + ["", "## Transcript", "", transcript, ""]).joined(separator: "\n")
}
