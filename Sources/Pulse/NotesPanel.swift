import AppKit
import SwiftUI

@MainActor
final class NotesPanel {
    static let shared = NotesPanel()
    private var panel: NSPanel?

    func show() {
        guard Meetings.shared.recording != nil else { return }
        let panel = self.panel ?? make()
        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func close() { panel?.orderOut(nil) }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Meeting notes"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: NotesPad())
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - 20, y: screen.minY + 20))
        }
        return panel
    }
}

private struct NotesPad: View {
    @ObservedObject private var meetings = Meetings.shared
    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        let meeting = meetings.recording
        let lines = ((meeting?.notes ?? []).map { ($0.at, $0.text) } + (meeting?.marks ?? []).map { ($0, markLine) }).sorted { $0.0 < $1.0 }
        VStack(alignment: .leading, spacing: 8) {
            Text(meeting.map { "Recording \($0.title)" } ?? "Not recording").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if lines.isEmpty { Text("Type what matters to you. The summary builds on your notes.").foregroundStyle(.secondary) }
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(String(format: "%d:%02d", Int(line.0) / 60, Int(line.0) % 60)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(line.1).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                            .id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: lines.count) { scroll.scrollTo(lines.count - 1, anchor: .bottom) }
            }
            HStack(spacing: 8) {
                TextField("Note", text: $draft, prompt: Text("Type a note and press Return"))
                    .textFieldStyle(.roundedBorder)
                    .focused($typing)
                    .onSubmit {
                        meetings.note(draft)
                        draft = ""
                    }
                Button { meetings.mark() } label: { Image(systemName: "star") }
                    .help("Mark this moment so the summary focuses on what's being said")
                    .accessibilityLabel("Mark this moment")
            }
            .disabled(meeting == nil)
        }
        .padding(12)
        .frame(minWidth: 260, minHeight: 160)
        .onAppear { typing = true }
    }
}
