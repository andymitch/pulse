import SwiftUI

struct MeetingsView: View {
    @ObservedObject private var meetings = Meetings.shared
    var limit = Int.max
    var open: (() -> Void)?

    var body: some View {
        if meetings.shown {
            SectionHeader(title: "Meetings", open: open) {
                if let recording = meetings.recording {
                    if meetings.noAudio {
                        Label("Recording \(recording.title), but some audio isn't coming in", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                            .help("Pulse retries every few seconds. Unlock the screen, or check Microphone and Screen & System Audio Recording for Pulse in System Settings > Privacy & Security.")
                    } else {
                        Label("Recording \(recording.title)", systemImage: "record.circle").font(.caption).foregroundStyle(.red)
                    }
                    Button("Stop") { Task { await meetings.stop(skip: true) } }
                } else {
                    if meetings.transcribing {
                        ProgressView().controlSize(.small)
                        Text("Transcribing…").font(.caption).foregroundStyle(.secondary)
                    }
                    if settings.recordMeetings {
                        Button("Start recording") { Task { await meetings.startManually() } }
                    }
                }
            }
            if meetings.saved.isEmpty {
                Panel(title: "Meetings") { Text("No recorded meetings yet.").foregroundStyle(.secondary) }
            }
            let days = Dictionary(grouping: meetings.saved.prefix(limit)) { Calendar.current.startOfDay(for: $0.start) }
            ForEach(days.keys.sorted(by: >), id: \.self) { day in
                Text(dayLabel(day)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(days[day]!) { MeetingCard(meeting: $0) }
            }
        }
    }

    private func dayLabel(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }
}

private struct MeetingCard: View {
    let meeting: SavedMeeting
    @State private var copied = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(meeting.title).font(.headline)
                Spacer()
                Button { copy() } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Copy the notes and transcript as Markdown")
                Button { confirmDelete = true } label: { Image(systemName: "trash").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Delete this meeting")
                    .confirmationDialog("Delete \(meeting.title)?", isPresented: $confirmDelete) {
                        Button("Move to Trash", role: .destructive) { Meetings.shared.delete(meeting) }
                    } message: {
                        Text("The notes and transcript move to the Trash.")
                    }
            }
            Text(meeting.recorded).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(meeting.recorded)
            Text(meeting.summary.isEmpty ? "No summary. Copy it for the transcript." : meeting.summary)
                .foregroundStyle(meeting.summary.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !meeting.decisions.isEmpty || !meeting.points.isEmpty {
                DisclosureGroup("\(meeting.decisions.count) decisions, \(meeting.points.count) important points") {
                    VStack(alignment: .leading, spacing: 4) {
                        list("Decisions", meeting.decisions)
                        list("Important points", meeting.points)
                    }
                    .padding(.top, 6)
                }
                .font(.callout)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func copy() {
        guard let markdown = try? String(contentsOf: meeting.file, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    @ViewBuilder private func list(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(markdown("• " + item)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
