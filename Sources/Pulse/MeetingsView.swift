import SwiftUI

struct MeetingsView: View {
    @ObservedObject private var meetings = Meetings.shared

    var body: some View {
        if settings.meetings.contains(.record) || !meetings.saved.isEmpty {
            SectionHeader(title: "Meetings") {
                if let recording = meetings.recording {
                    Label("Recording \(recording.title)", systemImage: "record.circle").font(.caption).foregroundStyle(.red)
                    Button("Stop") { Task { await meetings.stop(skip: true) } }
                } else {
                    if meetings.transcribing {
                        ProgressView().controlSize(.small)
                        Text("Transcribing…").font(.caption).foregroundStyle(.secondary)
                    }
                    if settings.meetings.contains(.record) {
                        Button("Start recording") { Task { await meetings.startManually() } }
                    }
                }
            }
            if let error = meetings.error { Text(error).font(.caption).foregroundStyle(.red) }
            if meetings.saved.isEmpty {
                Panel(title: "Meetings") { Text("No recorded meetings yet.").foregroundStyle(.secondary) }
            }
            let days = Dictionary(grouping: meetings.saved) { Calendar.current.startOfDay(for: $0.start) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(meeting.title).font(.headline)
                Spacer()
                Button { open(meeting.file) } label: { Image(systemName: "doc.text").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Open the notes and transcript")
            }
            Text(meeting.recorded).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(meeting.recorded)
            Text(meeting.summary.isEmpty ? "No summary. Open the file for the transcript." : meeting.summary)
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

    @ViewBuilder private func list(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(markdown("• " + item)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
