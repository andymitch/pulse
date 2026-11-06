import SwiftUI

struct PrioritiesView: View {
    @ObservedObject var store: Store

    var body: some View {
        if let s = store.synthesis {
            ForEach(Array(s.focus.enumerated()), id: \.offset) { _, f in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(markdown(f.headline)).font(.title3.weight(.semibold))
                        Spacer()
                        SpeakButton(text: "\(f.headline). \(f.summary)")
                    }
                    Text(markdown(f.summary)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    let cards = f.sources.compactMap { id in s.sources.first { $0.id == id } }
                    Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 8) {
                        ForEach(Array(stride(from: 0, to: cards.count, by: 2)), id: \.self) { i in
                            GridRow {
                                SourceCard(source: cards[i])
                                if i + 1 < cards.count { SourceCard(source: cards[i + 1]) } else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
        } else if !store.synthesizing {
            Panel(title: "Focus") { Text("No briefing yet. Pulse makes one each morning, or press Refresh.").foregroundStyle(.secondary) }
        }
    }
}

private struct SourceCard: View {
    let source: Synthesis.Source

    var body: some View {
        Button {
            if let url = URL(string: source.url) { openSource(url, kind: source.kind) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    SourceIcon(kind: source.kind, url: URL(string: source.url), size: 11)
                    Text(source.title).font(.caption.weight(.semibold)).lineLimit(1)
                }
                if let excerpt = source.excerpt {
                    Text(excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.leading)
                }
                Text([source.author, source.date].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.background.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(source.url)
    }
}


struct SourceIcon: View {
    let kind: String
    var url: URL?
    var size: CGFloat = 11

    private var session: Brand? {
        guard kind == "session", let name = url?.lastPathComponent else { return nil }
        return name.hasPrefix("claude-") ? .claude : name.hasPrefix("pi-") ? .pi : nil
    }

    var body: some View {
        switch kind {
        case "slack": Image(nsImage: Brand.slack.image(size: size))
        case "linear": Image(nsImage: Brand.linear.image(size: size))
        case "github": Image(nsImage: Brand.github.image(size: size))
        case "session" where session != nil: Image(nsImage: session!.image(size: size))
        default:
            Image(systemName: ["meeting": "waveform", "mail": "envelope", "session": "terminal"][kind] ?? "doc.text")
                .font(.system(size: size - 1)).frame(width: size, height: size)
        }
    }
}
