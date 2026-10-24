import Charts
import SwiftUI

private let palette: [Color] = [.blue, .green, .orange, .purple, .red, .teal, .yellow, .pink, .mint, .indigo, .brown, .cyan, .gray]

struct ContentView: View {
    @ObservedObject var store: Store
    @State private var metric = TrendMetric.prs
    @ObservedObject private var speaker = Speaker.shared
    @ObservedObject private var voice = NaturalVoice.shared
    @State private var askVoice = false
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Group {
            if store.showingSettings {
                SettingsView(store: store)
            } else {
                main
            }
        }
        .overlayScrollers()
        .background { if settings.solidBackground { Color(nsColor: .windowBackgroundColor).ignoresSafeArea() } }
    }

    private var main: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let error = store.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                TodayView(store: store)
                SectionHeader(title: "Focus") {
                    if store.synthesizing {
                        ProgressView().controlSize(.small)
                        Text("Reading your sources…").font(.caption).foregroundStyle(.secondary)
                    } else if let at = store.synthesizedAt {
                        Text("Briefing \(at, format: .relative(presentation: .named))").font(.caption).foregroundStyle(.secondary)
                    }
                    if let focus = store.synthesis?.focus, !focus.isEmpty {
                        let text = focus.map { "\($0.headline). \($0.summary)" }.joined(separator: "\n\n")
                        if voice.state == .downloading && !voice.settingUp {
                            HStack(spacing: 6) {
                                ProgressView(value: voice.progress).progressViewStyle(.circular).controlSize(.small)
                                Text("Downloading voice \(Int(voice.progress * 100))%").font(.caption).foregroundStyle(.secondary)
                            }
                        } else if voice.settingUp {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Setting up voice…").font(.caption).foregroundStyle(.secondary)
                            }
                        } else if speaker.preparing {
                            ProgressView().controlSize(.small).help("Preparing speech")
                        } else {
                            Button {
                                if !settings.naturalVoice && !settings.voiceAsked && voice.supported && !speaker.speaking {
                                    askVoice = true
                                } else {
                                    speaker.toggle(text)
                                }
                            } label: {
                                Image(systemName: speaker.speaking ? "stop.fill" : "speaker.wave.2.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(speaker.speaking ? "Stop reading" : "Read the focus aloud")
                            .popover(isPresented: $askVoice, arrowEdge: .bottom) { voicePrompt(text) }
                        }
                    }
                    Button(store.synthesis == nil ? "Generate" : "Regenerate") { Task { await store.synthesize() } }
                        .disabled(store.synthesizing)
                }
                PrioritiesView(store: store)
                SectionHeader(title: "Trends") {
                    Picker("", selection: $metric) {
                        ForEach(TrendMetric.allCases.filter { $0 == .prs || store.hasLinearKey }, id: \.self) { m in
                            Label { Text(m.rawValue) } icon: { Image(nsImage: m.brand.padded(size: 13, trailing: 5)) }.tag(m)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Picker("", selection: $store.range) {
                        ForEach(TrendRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    PeoplePicker(store: store)
                }
                trends
            }
            .padding(16)
        }
    }

    @ViewBuilder private var trends: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch metric {
            case .prs:
                StackedChart(store: store, counts: prCounts, unit: "PRs")
                PRStatsTable(store: store)
            case .closed:
                StackedChart(store: store, counts: store.trends.completed, unit: "Tickets")
                Text("Tickets completed, by assignee.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func voicePrompt(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Use a natural voice?").font(.headline)
            Text("Pulse can read the focus with Kokoro, a natural voice that runs on your Mac. It's a one-time \(NaturalVoice.size) download. You can change this later in Settings.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Not now") {
                    remember(natural: false)
                    speaker.toggle(text)
                }
                Button("Download") {
                    remember(natural: true)
                    Task {
                        await voice.download()
                        if voice.state == .ready { speaker.toggle(text) }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func remember(natural: Bool) {
        askVoice = false
        settings.voiceAsked = true
        settings.naturalVoice = natural
        try? settings.save()
    }

    private var prCounts: [Count] {
        Dictionary(grouping: store.trends.prs) { [$0.bucket, $0.person] }
            .map { Count(bucket: $0.key[0], person: $0.key[1], n: $0.value.count) }
    }

    private var header: some View {
        HStack {
            Text("Pulse").font(.title3.bold())
            Spacer()
            if store.syncing {
                ProgressView().controlSize(.small)
                Text("Syncing…").foregroundStyle(.secondary)
            } else if let last = store.lastSync {
                Text("Synced \(last, format: .relative(presentation: .named))").foregroundStyle(.secondary)
            }
            if updater.installing {
                ProgressView().controlSize(.small)
                Text("Updating…").foregroundStyle(.secondary)
            } else if let release = updater.available {
                Button { Task { await updater.install() } } label: { Label("Update to \(release.tag_name)", systemImage: "arrow.down.circle") }
                    .buttonStyle(.borderedProminent)
                    .help(updater.error ?? "Install the update and relaunch Pulse")
            }
            Button("Refresh") { Task { await store.refresh() } }.disabled(store.syncing)
            Button { store.showingSettings = true } label: {
                Image(systemName: "gear").font(.system(size: 17)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }
}

enum TrendMetric: String, CaseIterable {
    case prs = "PRs merged", closed = "Tickets closed"

    var brand: Brand { self == .prs ? .github : .linear }
}

struct SectionHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.headline)
            Spacer()
            accessory
        }
        .padding(.top, 10)
    }
}

struct PeoplePicker: View {
    @ObservedObject var store: Store

    private var label: String {
        switch store.selected.count {
        case 0: "Everyone"
        case 1: store.selected.first == store.me ? "Just me" : store.selected.first!
        default: "\(store.selected.count) people"
        }
    }

    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Label(label, systemImage: "person.2") }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button("Everyone") { store.selected = [] }
                        if let me = store.me { Button("Just me") { store.selected = [me] } }
                    }
                    Divider()
                    ForEach(store.people, id: \.self) { p in
                        Toggle(p, isOn: Binding(get: { store.selected.contains(p) }, set: { _ in store.toggle(p) }))
                    }
                }
                .padding(12)
            }
    }
}

struct Panel<Accessory: View, Content: View>: View {
    let title: String
    var brand: Brand?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 7) {
                if let brand { Image(nsImage: brand.image(size: 12)).foregroundStyle(.secondary) }
                Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                accessory
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

extension Panel where Accessory == EmptyView {
    init(title: String, brand: Brand? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, brand: brand, accessory: { EmptyView() }, content: content)
    }
}


struct StackedChart: View {
    @ObservedObject var store: Store
    let counts: [Count]
    let unit: String

    private struct Bar: Identifiable {
        let bucket, person: String
        let n, order: Int
        var id: String { bucket + person }
    }

    var body: some View {
        let everyone = store.people
        let present = Set(counts.map(\.person))
        let shown = everyone.filter { present.contains($0) && store.includes($0) }
        let bars = store.buckets.flatMap { m in
            counts.filter { $0.bucket == m && store.includes($0.person) }
                .sorted { ($0.n, $1.person) > ($1.n, $0.person) }
                .enumerated()
                .map { Bar(bucket: m, person: $1.person, n: $1.n, order: $0) }
        }

        Chart(bars) { b in
            BarMark(x: .value("Period", store.label(b.bucket)), y: .value(unit, b.n), stacking: .standard)
                .foregroundStyle(by: .value("Person", b.person))
                .zIndex(Double(-b.order))
        }
        .chartXScale(domain: store.buckets.map(store.label))
        .chartForegroundStyleScale(domain: shown, range: shown.map { palette[store.colorIndex($0) % palette.count] })
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: 200)
    }
}

private func hours(_ h: Double) -> String {
    h >= 48 ? String(format: "%.1fd", h / 24) : String(format: "%.1fh", h)
}

struct PRStatsTable: View {
    @ObservedObject var store: Store

    var body: some View {
        let stats = prStats(store.trends.prs.filter { store.includes($0.person) })
        Grid(alignment: .trailing, horizontalSpacing: 6, verticalSpacing: 4) {
            GridRow {
                Text("")
                ForEach(store.buckets, id: \.self) { Text(store.label($0)).foregroundStyle(.secondary) }
            }
            Divider()
            row("Merged", stats) { "\($0.merged)" }
            row("Median time to merge", stats) { hours($0.medianHours) }
            row("Median lines added", stats) { "\(Int($0.medianAdditions))" }
            row("PRs over 500 lines", stats) { "\($0.over500)" }
        }
        .font(.caption.monospacedDigit())
    }

    private func row(_ label: String, _ stats: [String: PrStats], _ value: @escaping (PrStats) -> String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            ForEach(store.buckets, id: \.self) { m in Text(stats[m].map(value) ?? "–") }
        }
    }
}

struct LinearKeyForm: View {
    @ObservedObject var store: Store
    @State private var key = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        Text("Paste a Linear personal API key (Settings → Security & access). It's stored in your Keychain.")
        HStack {
            SecureField("lin_api_…", text: $key).frame(width: 320).onSubmit(save)
            Button("Save", action: save).disabled(blank || saving)
        }
        if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }

    private var blank: Bool { key.trimmingCharacters(in: .whitespaces).isEmpty }

    private func save() {
        guard !blank, !saving else { return }
        saving = true
        error = nil
        Task {
            do { try await store.saveLinearKey(key); key = "" } catch { self.error = "\(error)" }
            saving = false
        }
    }
}
