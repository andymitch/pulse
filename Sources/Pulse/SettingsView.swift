import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: Store
    @State private var draft = settings
    @State private var accounts: [String] = []
    @State private var orgs: [String] = []
    @State private var replacingKey = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { store.showingSettings = false } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.plain)
                Spacer()
                Button("Save", action: save).keyboardShortcut("s").disabled(draft == settings)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)
            form.clipped().overlayScrollers()
        }
        .task { await loadGitHub() }
        .onChange(of: draft.githubAccount) { Task { await loadGitHub() } }
    }

    private var form: some View {
        Form {
            Section {
                if accounts.isEmpty {
                    Text("Sign in to GitHub with the GitHub CLI to see PRs and reviews.")
                    HStack {
                        Button("Sign in to GitHub") { try? openCommandInTerminal("gh auth login --web") }
                        Link("Get the GitHub CLI", destination: URL(string: "https://cli.github.com")!)
                    }
                } else {
                    Picker("Account", selection: $draft.githubAccount) {
                        ForEach(accounts, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Organization", selection: $draft.githubOrg) {
                        Text("None").tag("")
                        ForEach(orgs, id: \.self) { Text($0).tag($0) }
                    }
                }
            } header: { header("GitHub", .github) }

            Section {
                if store.hasLinearKey && !replacingKey {
                    LabeledContent("API key", value: "Saved in Keychain")
                    HStack {
                        Button("Replace") { replacingKey = true }
                        Button("Remove", role: .destructive) {
                            removeLinearKey()
                            store.hasLinearKey = false
                        }
                        Spacer()
                        Link("Manage keys in Linear", destination: URL(string: "https://linear.app/settings/account/security")!)
                    }
                } else {
                    LinearKeyForm(store: store)
                    Link("Create a personal API key in Linear", destination: URL(string: "https://linear.app/settings/account/security")!)
                        .font(.caption)
                }
                ConnectionRow(service: .linear)
            } header: { header("Linear", .linear) }
            .onChange(of: store.hasLinearKey) { replacingKey = false }

            Section {
                Toggle("Read Slack in the briefing", isOn: $draft.slack)
                if draft.slack {
                    ConnectionRow(service: .slack)
                    ChannelPicker(selected: $draft.slackChannels)
                }
            } header: { header("Slack", .slack) }

            Section {
                Toggle("Read Mail inbox in the briefing", isOn: $draft.mail)
                if draft.mail { Stepper("Last \(draft.mailDays) days", value: $draft.mailDays, in: 1...14) }
            } header: { header("Mail", nil, symbol: "envelope") } footer: {
                note("Uses the accounts in Mail.app. macOS asks once for permission to read Mail.")
            }

            Section {
                ForEach(MeetingSource.allCases, id: \.self) { source in
                    Toggle(isOn: member(source, of: $draft.meetings)) {
                        Text(source.name)
                        Text(source.setup)
                    }
                }
                MeetingStatus()
            } header: { header("Meetings", nil, symbol: "waveform") }

            Section {
                VoiceRow(on: $draft.naturalVoice, asked: $draft.voiceAsked)
            } header: { header("Voice", nil, symbol: "speaker.wave.2") }

            Section {
                UpdatesRow(beta: $draft.betaUpdates)
            } header: { header("Updates", nil, symbol: "arrow.down.circle") }

            Section {
                Toggle(isOn: $draft.solidBackground) {
                    Text("Solid background")
                    Text("Turns off the see-through popover background, for better contrast.")
                }
            } header: { header("Accessibility", nil, symbol: "accessibility") }

            Section {
                TextField("Repository", text: $draft.repoPath, prompt: Text("~/code/app"))
                TextField("Worktrees folder", text: $draft.worktreeRoot)
                ForEach(IDE.allCases, id: \.self) { ide in
                    Toggle(isOn: member(ide, of: $draft.ides)) {
                        Label { Text(ide.installed ? ide.name : "\(ide.name) (not installed)") } icon: { Image(nsImage: ide.brand.image(size: 14)) }
                    }
                    .disabled(!ide.installed)
                }
            } header: { header("Code", nil, symbol: "chevron.left.forwardslash.chevron.right") } footer: {
                note("IDEs open the worktree and pass the prompt to their own agent panel, using the agent you last used there.")
            }

            Section {
                ForEach(Array(draft.agents.indices), id: \.self) { i in
                    HStack {
                        Toggle("", isOn: $draft.agents[i].enabled)
                        Group {
                            if let brand = draft.agents[i].brand { Image(nsImage: brand.image(size: 14)) } else { Image(systemName: "terminal").font(.system(size: 12)) }
                        }
                        .frame(width: 16)
                        TextField("Name", text: $draft.agents[i].name, prompt: Text("Name")).frame(width: 120)
                        TextField("Command", text: $draft.agents[i].command, prompt: Text("agent {prompt}"))
                        Button { draft.agents.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                    .labelsHidden()
                }
                Button("Add agent") { draft.agents.append(Agent(name: "New agent", command: "agent {prompt}")) }
            } header: { header("Terminal agents", nil, symbol: "terminal") } footer: {
                note("Open in your default terminal, \(terminalName). {prompt} is the path of a file holding the ticket prompt.")
            }

            Section {
                Picker("Agent", selection: $draft.briefingCommand) {
                    ForEach(Settings.briefingPresets, id: \.command) { Text($0.name).tag($0.command) }
                    if !Settings.briefingPresets.contains(where: { $0.command == draft.briefingCommand }) { Text("Custom").tag(draft.briefingCommand) }
                }
                TextField("Command", text: $draft.briefingCommand)
                Stepper("Each morning after \(draft.briefingHour):00", value: $draft.briefingHour, in: 0...23)
            } header: { header("Briefing", nil, symbol: "sparkles") } footer: {
                note("The briefing reads your sources with this agent and writes one file that Pulse checks. It never posts.")
            }
        }
        .formStyle(.grouped)
    }

    private func header(_ title: String, _ brand: Brand?, symbol: String = "") -> some View {
        HStack(spacing: 6) {
            if let brand { Image(nsImage: brand.image(size: 13)) } else { Image(systemName: symbol).font(.system(size: 12)).frame(width: 13, height: 13) }
            Text(title)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func loadGitHub() async {
        let account = draft.githubAccount
        let found = await Task.detached { ghAccounts() }.value
        accounts = found
        if !found.contains(account), let first = found.first { draft.githubAccount = first; return }
        orgs = await Task.detached { ghOrgs(account: account) }.value
        if !draft.githubOrg.isEmpty && !orgs.contains(draft.githubOrg) { orgs.insert(draft.githubOrg, at: 0) }
    }

    private func save() {
        do {
            try draft.save()
            settings = draft
            store.load()
            store.showingSettings = false
            Task { await store.refresh() }
        } catch {
            store.lastError = "\(error)"
        }
    }

    private func member<T: Equatable>(_ value: T, of list: Binding<[T]>) -> Binding<Bool> {
        Binding(get: { list.wrappedValue.contains(value) }, set: { on in
            list.wrappedValue.removeAll { $0 == value }
            if on { list.wrappedValue.append(value) }
        })
    }
}

struct ConnectionRow: View {
    let service: MCPService
    @State private var connected: Bool?
    @State private var connecting = false
    @State private var error: String?

    private var agent: BriefingAgent { .current }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Briefing access")
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if connecting || connected == nil {
                ProgressView().controlSize(.small)
            } else if connected == true {
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else if agent.installed {
                Button("Connect \(service.name)") { Task { await connect() } }
            } else {
                Link("Install \(agent.name)", destination: URL(string: agent == .pi ? "https://pi.dev" : "https://claude.com/claude-code")!)
            }
        }
        .task { await check() }
        if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(4) }
    }

    private var detail: String {
        if connected == true { return "\(agent.name) can read \(service.name) for the briefing. Pulse never posts." }
        if !agent.installed { return "The briefing runs on \(agent.name), which isn't installed." }
        return "Opens \(service.name) in your browser to let \(agent.name) read it. Pulse never posts."
    }

    private func check() async {
        let agent = agent
        connected = await Task.detached { agent.connected(service) }.value
    }

    private func connect() async {
        connecting = true
        error = nil
        let agent = agent
        do {
            try await Task.detached { try agent.connect(service) }.value
        } catch {
            self.error = "\(error)"
        }
        await check()
        connecting = false
    }
}

struct ChannelPicker: View {
    @Binding var selected: [SlackChannel]
    @State private var open = false
    @State private var all: [SlackChannel] = []
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Channels")
                Spacer()
                Button { open = true; if all.isEmpty { all = cachedSlackChannels(); if all.isEmpty { Task { await load() } } } } label: {
                    Label("Add", systemImage: "plus")
                }
                    .popover(isPresented: $open, arrowEdge: .trailing) { list }
            }
            if selected.isEmpty {
                Text("None picked, so the briefing reads your busiest channels.").font(.caption).foregroundStyle(.secondary)
            } else {
                Flow(spacing: 6) {
                    ForEach(selected, id: \.id) { channel in
                        HStack(spacing: 4) {
                            Text("#\(channel.name)")
                            Button { selected.removeAll { $0.id == channel.id } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                .buttonStyle(.plain)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Search channels", text: $search).textFieldStyle(.roundedBorder)
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).disabled(loading).help("Refresh the channel list")
            }
            if loading {
                HStack { ProgressView().controlSize(.small); Text("Asking \(BriefingAgent.current.name) for your channels…").font(.caption) }
                    .padding(.vertical, 20)
            } else if let error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(6)
                Button("Try again") { Task { await load() } }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(all.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }, id: \.id) { channel in
                            Toggle("#\(channel.name)", isOn: Binding(
                                get: { selected.contains(channel) },
                                set: { on in
                                    selected.removeAll { $0.id == channel.id }
                                    if on { selected.append(channel) }
                                }))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 280)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private func load() async {
        loading = true
        error = nil
        do { all = try await fetchSlackChannels() } catch { self.error = "\(error)" }
        loading = false
    }
}

struct Flow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(bounds.width, subviews) {
            for (index, x) in row.items {
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(items: [(Int, CGFloat)], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(items: [(Int, CGFloat)], y: CGFloat, width: CGFloat, height: CGFloat)] = []
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0, items: [(Int, CGFloat)] = []
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                rows.append((items, y, x - spacing, height))
                y += height + spacing
                x = 0; height = 0; items = []
            }
            items.append((i, x))
            x += size.width + spacing
            height = max(height, size.height)
        }
        if !items.isEmpty { rows.append((items, y, x - spacing, height)) }
        return rows
    }
}

struct VoiceRow: View {
    @Binding var on: Bool
    @Binding var asked: Bool
    @ObservedObject private var voice = NaturalVoice.shared

    var body: some View {
        Toggle(isOn: $on) {
            Text("Natural voice for reading the focus aloud")
            Text(detail)
        }
        .disabled(!voice.supported)
        .onChange(of: on) {
            asked = true
            if on && voice.state != .ready && voice.state != .downloading { Task { await voice.download() } }
        }
        if voice.state == .downloading {
            HStack {
                if voice.settingUp {
                    ProgressView().controlSize(.small)
                    Text("Setting up voice…").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView(value: voice.progress).progressViewStyle(.circular).controlSize(.small)
                    Text("Downloading Kokoro, \(Int(voice.progress * 100))% of \(NaturalVoice.size)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if case .failed(let message) = voice.state {
            HStack {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
                Button("Retry") { Task { await voice.download() } }
            }
        }
        if voice.state == .ready {
            HStack {
                Text("Kokoro is downloaded.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Remove", role: .destructive) { voice.remove(); on = false }
            }
        }
    }

    private var detail: String {
        if !voice.supported { return "Needs macOS 15 or later. Pulse uses the system voice." }
        return "Kokoro, an open on-device voice. Downloads \(NaturalVoice.size) once; until then, and when off, Pulse uses the system voice."
    }
}

struct MeetingStatus: View {
    @ObservedObject private var meetings = Meetings.shared

    var body: some View {
        if let meeting = meetings.recording {
            HStack {
                Label("Recording \(meeting.title)", systemImage: "record.circle").foregroundStyle(.red)
                Spacer()
                Button("Stop") { Task { await meetings.stop(skip: true) } }
            }
        } else if meetings.transcribing {
            HStack {
                ProgressView().controlSize(.small)
                Text("Transcribing and summarizing a meeting…").font(.caption).foregroundStyle(.secondary)
            }
        }
        if let error = meetings.error { Text(error).font(.caption).foregroundStyle(.red) }
    }
}

struct UpdatesRow: View {
    @Binding var beta: Bool
    @ObservedObject private var updater = Updater.shared
    @State private var checking = false

    var body: some View {
        HStack {
            Text("Pulse \(updater.current)")
            Spacer()
            if updater.devBuild {
                Text("Local build, updates are off").font(.caption).foregroundStyle(.secondary)
            } else if checking {
                ProgressView().controlSize(.small)
            } else if let release = updater.available {
                Button("Update to \(release.tag_name)") { Task { await updater.install() } }
            } else {
                Button("Check now") {
                    checking = true
                    Task { await updater.check(); checking = false }
                }
            }
        }
        if let error = updater.error { Text(error).font(.caption).foregroundStyle(.red) }
        Toggle(isOn: $beta) {
            Text("Beta updates")
            Text("Also offer pre-releases. You move back to stable when the next stable release ships.")
        }
    }
}
