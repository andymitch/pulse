import SwiftUI

struct PrioritiesView: View {
    @ObservedObject var store: Store
    var headlines = false

    var body: some View {
        if let s = store.synthesis {
            ForEach(Array(s.focus.enumerated()), id: \.offset) { _, f in
                VStack(alignment: .leading, spacing: 10) {
                    Text(markdown(f.headline)).font(.title3.weight(.semibold))
                    if !headlines {
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
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
        } else if !store.synthesizing {
            Panel(title: "Focus") { Text("No briefing yet. Pulse makes one each morning, or press Generate.").foregroundStyle(.secondary) }
        }
    }
}

private struct SourceCard: View {
    let source: Synthesis.Source

    private var brand: Brand? {
        switch source.kind {
        case "slack": .slack
        case "linear": .linear
        case "github": .github
        default: nil
        }
    }

    private var symbol: String {
        switch source.kind {
        case "meeting": "waveform"
        case "mail": "envelope"
        default: "doc.text"
        }
    }

    private var app: App? {
        switch source.kind {
        case "slack": .slack
        case "linear": .linear
        default: nil
        }
    }

    var body: some View {
        Button {
            if let url = URL(string: source.url) { open(url, in: app) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    if let brand { Image(nsImage: brand.image(size: 11)) } else { Image(systemName: symbol).font(.system(size: 10)).frame(width: 11, height: 11) }
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
