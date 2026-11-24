import AppKit
import SwiftUI

private final class StickyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class NotesPanel {
    static let shared = NotesPanel()
    private var panel: NSPanel?

    func show() {
        let panel = self.panel ?? make()
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func close() { panel?.orderOut(nil) }

    private func make() -> NSPanel {
        let panel = StickyPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 200), styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
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

    var body: some View {
        let meeting = meetings.recording
        let lines = ((meeting?.notes ?? []).map { ($0.at, $0.text) } + (meeting?.marks ?? []).map { ($0, markLine) }).sorted { $0.0 < $1.0 }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 7, height: 7)
                Text(meeting?.title ?? "Notes").font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { meetings.mark() } label: { Image(systemName: "star") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Mark this moment so the summary focuses on what's being said")
                    .accessibilityLabel("Mark this moment")
            }
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(String(format: "%d:%02d", Int(line.0) / 60, Int(line.0) % 60)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                Text(line.1).fixedSize(horizontal: false, vertical: true)
                            }
                            .id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                .onChange(of: lines.count) { scroll.scrollTo(lines.count - 1, anchor: .bottom) }
            }
            TextField("Note", text: $draft, prompt: Text("Type what matters…"))
                .textFieldStyle(.plain)
                .onSubmit {
                    meetings.note(draft)
                    draft = ""
                }
        }
        .font(.callout)
        .padding(12)
        .frame(minWidth: 220, minHeight: 140)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
