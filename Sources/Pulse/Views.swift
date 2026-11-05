import Charts
import SwiftUI

private let palette: [Color] = [.blue, .green, .orange, .purple, .red, .teal, .yellow, .pink, .mint, .indigo, .brown, .cyan, .gray]

struct ContentView: View {
    @ObservedObject var store: Store
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var meetings = Meetings.shared

    var body: some View {
        Group {
            if store.showingSettings {
                SettingsView(store: store)
            } else {
                main
            }
        }
        .overlayScrollers()
        .environment(\.openURL, OpenURLAction { url in
            openLink(url)
            return .handled
        })
        .background { if settings.solidBackground { Color(nsColor: .windowBackgroundColor).ignoresSafeArea() } }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ForEach(Array([store.lastError, store.synthesisError, meetings.error].compactMap { $0 }.enumerated()), id: \.offset) { _, error in
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(4).help(error).padding(.horizontal, 16)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch store.page {
                    case .home: home
                    case .meetings: MeetingsView()
                    case .knowledge: KnowledgeView(store: store)
                    case .trends: trends
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .id(store.page)
            .overlayScrollers()
        }
        .padding(.top, 16)
        .onChange(of: meetings.shown) { _, shown in
            if !shown, store.page == .meetings { store.page = .home }
        }
    }

    @ViewBuilder private var home: some View {
        WeeklyPace(store: store)
        TodayView(store: store)
        FocusHeader(store: store)
        PrioritiesView(store: store)
        MeetingsView(todayOnly: true) { store.page = .meetings }
    }

    @ViewBuilder private var trends: some View {
        SectionHeader(title: "Trends") {
            Picker("", selection: $store.range) {
                ForEach(TrendRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            PeoplePicker(people: store.people, me: store.me, selection: $store.selected)
        }
        Panel(title: "PRs merged", brand: .github) {
            StackedChart(store: store, counts: prCounts, unit: "PRs")
            PRStatsTable(store: store, prs: store.trends.prs.filter { store.includes($0.person) })
        }
        if store.hasLinearKey {
            Panel(title: "Tickets closed", brand: .linear) {
                StackedChart(store: store, counts: store.trends.completed, unit: "Tickets")
                Text("Tickets completed, by assignee.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var prCounts: [Count] {
        Dictionary(grouping: store.trends.prs) { [$0.bucket, $0.person] }
            .map { Count(bucket: $0.key[0], person: $0.key[1], n: $0.value.count) }
    }

    private var header: some View {
        HStack {
            Text("Pulse").font(.title3.bold())
            Picker("", selection: $store.page) {
                ForEach(PulseTab.allCases.filter { $0 != .meetings || meetings.shown }, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.leading, 8)
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
        .padding(.horizontal, 16)
    }
}

enum PulseTab: String, CaseIterable {
    case home = "Home", knowledge = "Knowledge", meetings = "Meetings", trends = "Trends"
}


struct SectionHeader<Accessory: View>: View {
    let title: String
    var open: (() -> Void)?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 8) {
            if let open {
                Button(action: open) {
                    HStack(spacing: 4) {
                        Text(title).font(.headline)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Open \(title)")
            } else {
                Text(title).font(.headline)
            }
            Spacer()
            accessory
        }
        .padding(.top, 10)
    }
}

struct PeoplePicker: View {
    let people: [String]
    let me: String?
    @Binding var selection: Set<String>
    @State private var open = false

    private var label: String {
        switch selection.count {
        case 0: "Everyone"
        case 1: selection.first == me ? "Just me" : selection.first!
        default: "\(selection.count) people"
        }
    }

    var body: some View {
        Button { open.toggle() } label: { Label(label, systemImage: "person.2") }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button("Everyone") { selection = [] }
                        if let me, !me.isEmpty { Button("Just me") { selection = [me] } }
                    }
                    Divider()
                    ForEach(people, id: \.self) { p in
                        Toggle(p, isOn: Binding(get: { selection.contains(p) }, set: { on in if on { selection.insert(p) } else { selection.remove(p) } }))
                    }
                }
                .padding(12)
            }
    }
}

struct WeeklyPace: View {
    @ObservedObject var store: Store

    var body: some View {
        let target = max(settings.weeklyPRTarget, 1), merged = store.mergedThisWeek
        if !settings.githubAccount.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("PRs merged this week").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(merged) of \(target)").font(.caption.monospacedDigit()).foregroundStyle(merged >= target ? .green : .secondary)
                }
                ProgressView(value: Double(min(merged, target)), total: Double(target))
                    .tint(merged >= target ? .green : .accentColor)
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("PRs merged this week: \(merged) of \(target)")
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
    @State private var selected: String?

    private struct Bar: Identifiable {
        let bucket, person: String
        let n, order: Int
        var id: String { bucket + person }
    }

    var body: some View {
        let present = Set(counts.map(\.person))
        let shown = store.people.filter { present.contains($0) && store.includes($0) }
        let bars = store.buckets.flatMap { m in
            counts.filter { $0.bucket == m && store.includes($0.person) }
                .sorted { ($0.n, $1.person) > ($1.n, $0.person) }
                .enumerated()
                .map { Bar(bucket: m, person: $1.person, n: $1.n, order: $0) }
        }

        Chart {
            ForEach(bars) { b in
                BarMark(x: .value("Period", store.label(b.bucket)), y: .value(unit, b.n), stacking: .standard)
                    .foregroundStyle(by: .value("Person", b.person))
                    .zIndex(Double(-b.order))
            }
            if let selected {
                RuleMark(x: .value("Period", selected))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .zIndex(1)
                    .annotation(position: .trailing, alignment: .top, spacing: 6, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        tooltip(selected, bars.filter { store.label($0.bucket) == selected })
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartXScale(domain: store.buckets.map(store.label))
        .chartForegroundStyleScale(domain: shown, range: shown.map { palette[store.colorIndex($0) % palette.count] })
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: 200)
    }

    private func tooltip(_ period: String, _ bars: [Bar]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(period).font(.caption.weight(.semibold))
            ForEach(bars) { b in
                HStack(spacing: 6) {
                    Circle().fill(palette[store.colorIndex(b.person) % palette.count]).frame(width: 7, height: 7)
                    Text(b.person)
                    Spacer(minLength: 12)
                    Text("\(b.n)").monospacedDigit()
                }
            }
            Divider()
            HStack {
                Text("Total")
                Spacer(minLength: 12)
                let total = bars.map(\.n).reduce(0, +)
                Text("\(total) \(total == 1 ? String(unit.dropLast()) : unit)").monospacedDigit()
            }
            .fontWeight(.semibold)
        }
        .font(.caption)
        .padding(8)
        .frame(minWidth: 150)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .shadow(radius: 3)
    }
}

private func hours(_ h: Double) -> String {
    h >= 48 ? String(format: "%.1fd", h / 24) : String(format: "%.1fh", h)
}

struct PRStatsTable: View {
    @ObservedObject var store: Store
    let prs: [PRRow]

    var body: some View {
        let stats = prStats(prs)
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

struct SpeakButton: View {
    let text: String
    @ObservedObject private var speaker = Speaker.shared
    @ObservedObject private var voice = NaturalVoice.shared
    @State private var asking = false
    @State private var downloading = false

    var body: some View {
        let active = speaker.text == text
        if downloading, voice.state == .downloading {
            status(voice.settingUp ? "Setting up voice…" : "Downloading voice \(Int(voice.progress * 100))%")
        } else if active, voice.settingUp {
            status("Setting up voice…")
        } else if active, speaker.preparing {
            ProgressView().controlSize(.small).help("Preparing speech")
        } else {
            Button {
                if !settings.naturalVoice && !settings.voiceAsked && voice.supported && !active {
                    asking = true
                } else {
                    speaker.toggle(text)
                }
            } label: {
                Image(systemName: active ? "stop.fill" : "speaker.wave.2.fill").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(active ? "Stop reading" : "Read aloud")
            .accessibilityLabel(active ? "Stop reading" : "Read aloud")
            .popover(isPresented: $asking, arrowEdge: .bottom) { prompt }
        }
    }

    private func status(_ label: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Use a natural voice?").font(.headline)
            Text("Pulse can read aloud with Kokoro, a natural voice that runs on your Mac. It's a one-time \(NaturalVoice.size) download. You can change this later in Settings.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Not now") {
                    remember(natural: false)
                    speaker.toggle(text)
                }
                Button("Download") {
                    remember(natural: true)
                    downloading = true
                    Task {
                        await voice.download()
                        downloading = false
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
        asking = false
        settings.voiceAsked = true
        settings.naturalVoice = natural
        try? settings.save()
    }
}

struct FocusHeader: View {
    @ObservedObject var store: Store

    var body: some View {
        SectionHeader(title: "Focus") {
            if store.synthesizing {
                ProgressView().controlSize(.small)
                Text("Reading your sources…").font(.caption).foregroundStyle(.secondary)
            } else if let at = store.synthesizedAt {
                Text("Briefing \(at, format: .relative(presentation: .named))").font(.caption).foregroundStyle(.secondary)
            }
            Button(store.synthesis == nil ? "Generate" : "Regenerate") { Task { await store.synthesize() } }
                .disabled(store.synthesizing)
        }
    }
}
