import SwiftUI
import ServiceManagement
import StoplightCore

/// US-008 (General) + US-013 (Sources).
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            DisplayTab(model: model)
                .tabItem { Label("Display", systemImage: "paintpalette") }
            SourcesTab(model: model)
                .tabItem { Label("Sources", systemImage: "person.2") }
            AgentSettingsTab(model: model)
                .tabItem { Label("Agent", systemImage: "sparkles") }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 680)
    }
}

private struct GeneralTab: View {
    @Bindable var model: AppModel
    @AppStorage(Prefs.notifications) private var notifications = "all"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section {
                switch model.auth {
                case .signedIn(let login, let source):
                    LabeledContent("Signed in as", value: "@\(login)")
                    LabeledContent("Source", value: source.rawValue)
                    Button("Sign out") { model.signOut() }
                case .failed(let msg):
                    Text(msg).foregroundStyle(prefs.colorProfile.color(for: .failure))
                default:
                    Text("Not signed in").foregroundStyle(.secondary)
                }
                LabeledContent("GitHub CLI") {
                    HStack(spacing: 8) {
                        Text(TokenSource.ghPath() ?? "Not found")
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(TokenSource.ghPath() == nil ? prefs.colorProfile.color(for: .failure) : .secondary)
                        if !prefs.ghPath.isEmpty { Button("Automatic") { prefs.ghPath = ""; reauth() } }
                        Button("Choose…") { chooseGH() }
                    }
                }
            } header: {
                Text("Account")
            } footer: {
                Text(TokenSource.ghPath() == nil
                     ? "Stoplight couldn't find gh. Choose it, or install the GitHub CLI."
                     : "Found on your shell's PATH. Choose another if gh lives somewhere unusual.")
            }

            Section("Notifications") {
                Picker("Notify me", selection: $notifications) {
                    Text("When a PR fails or turns all-passing").tag("all")
                    Text("Only when a PR fails").tag("failOnly")
                    Text("Never").tag("off")
                }
                .pickerStyle(.radioGroup)
            }

            Section("Startup") {
                Toggle("Open Stoplight at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section {
                LabeledContent("Version") {
                    HStack(spacing: 8) {
                        Text(model.updater.currentVersion).foregroundStyle(.secondary)
                        updateControl
                    }
                }
                LabeledContent("Guided tour") {
                    Button("Show Again") { model.prefs.tourSeen = false; model.openPanel?() }
                }
                HStack {
                    Spacer()
                    Button("Quit Stoplight") { NSApp.terminate(nil) }.keyboardShortcut("q")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// How Stoplight looks. The bulky parts stay folded until asked for.
private struct DisplayTab: View {
    @Bindable var model: AppModel

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section("Colors") {
                Picker("Color profile", selection: $prefs.colorProfile) {
                    ForEach(ColorProfile.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: prefs.colorProfile) { _, _ in model.colorProfileChanged() }
            }

            Section("Menu bar") {
                Toggle("Dark housing behind the dots", isOn: $prefs.housing)
                Toggle("Show a count beside the dots", isOn: $prefs.showCount)
            }

            Section {
                Picker("Counts on collapsed sections", selection: $prefs.sectionCounts) {
                    Text("Off").tag(UserPrefs.SectionCounts.off)
                    Text("Only what needs attention").tag(UserPrefs.SectionCounts.attention)
                    Text("Every state").tag(UserPrefs.SectionCounts.full)
                }
                DisclosureGroup("Row buttons") {
                    RowActionsEditor(prefs: prefs)
                    Text("The circles in an expanded PR. Check to show, drag to reorder.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Popover")
            } footer: {
                Text("The footer always tallies every section, which is what lights the menu bar.")
            }

            Section {
                DisclosureGroup("What the dots and badges mean") {
                    LegendRow("At least one check failed.") { StatusDot(state: .failure) }
                    LegendRow("Checks still running.") { StatusDot(state: .pending) }
                    LegendRow("Every check passed.") { StatusDot(state: .success) }
                    LegendRow("Nothing ran: no checks, or all of them skipped.") { StatusDot(state: .none) }
                    LegendRow("Draft. Never lights the menu bar or notifies.") { StatusDot(state: .success, hollow: true) }
                    LegendRow("Can't merge until conflicts are fixed. Counts as red.") {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption)
                            .foregroundStyle(prefs.colorProfile.color(for: .failure))
                    }
                    LegendRow("Merged. The branch badge shows how that branch is doing now.") {
                        Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.githubMerged)
                    }
                    LegendRow("In the merge queue at that position.") {
                        Image(systemName: "line.3.horizontal").font(.caption).foregroundStyle(.secondary)
                    }
                    LegendRow("Stacked on the PR above it.") {
                        Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    LegendRow("An agent you launched is waiting on you.") {
                        Image(systemName: "sparkles").font(.caption).foregroundStyle(.orange)
                    }
                }
            } footer: {
                Text("Double-click a PR to expand it, right-click for the rest, ⌘/ for every shortcut.")
            }
        }
        .formStyle(.grouped)
    }
}

private func legendTag(_ text: String, _ color: Color) -> some View {
    Text(text).font(.caption2).foregroundStyle(color)
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(.quaternary, in: Capsule())
}

private struct LegendRow<Icon: View>: View {
    @ViewBuilder let icon: () -> Icon
    let text: String
    init(_ text: String, @ViewBuilder icon: @escaping () -> Icon) { self.text = text; self.icon = icon }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon().frame(minWidth: 22, alignment: .center)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }
}

private extension GeneralTab {
    func reauth() { Task { await model.signIn(); await model.refresh() } }

    /// Pick the gh binary. Unsandboxed, so /opt and /usr/local are reachable.
    func chooseGH() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the gh executable"
        panel.directoryURL = URL(fileURLWithPath: (TokenSource.ghPath() as NSString?)?.deletingLastPathComponent ?? "/opt")
        if panel.runModal() == .OK, let url = panel.url {
            model.prefs.ghPath = url.path
            reauth()
        }
    }

    @ViewBuilder
    var updateControl: some View {
        let u = model.updater
        switch u.state {
        case .checking:
            ProgressView().controlSize(.small)
        case .downloading, .installing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Updating…").foregroundStyle(.secondary) }
        case .available:
            Button("Update to \(u.latest?.version ?? "")") { Task { await u.install() } }.buttonStyle(.borderedProminent)
        case .upToDate:
            Text("Up to date").foregroundStyle(.secondary)
            Button("Check Again") { Task { await u.check() } }
        case .failed(let msg):
            Text(msg).foregroundStyle(.red).font(.caption)
            Button("Retry") { Task { await u.check() } }
        case .idle:
            Button("Check for Updates") { Task { await u.check() } }
        }
    }
}

/// Check to include, drag to reorder (US-031). Unchecked actions sit at the bottom in their canonical order.
private struct RowActionsEditor: View {
    @Bindable var prefs: UserPrefs

    private var rows: [RowAction] {
        prefs.rowActions + RowAction.allCases.filter { !prefs.rowActions.contains($0) }
    }

    var body: some View {
        List {
            ForEach(rows) { a in
                let on = prefs.rowActions.contains(a)
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(get: { on }, set: { set(a, enabled: $0) })) { EmptyView() }.labelsHidden()
                    Image(systemName: a.symbol).frame(width: 18).foregroundStyle(on ? .primary : .secondary)
                    Text(a.title).foregroundStyle(on ? .primary : .secondary)
                    Spacer()
                    if on { Image(systemName: "line.3.horizontal").foregroundStyle(.quaternary) }
                }
                .moveDisabled(!on)
            }
            .onMove { from, to in
                var enabled = prefs.rowActions
                enabled.move(fromOffsets: from, toOffset: min(to, enabled.count))
                prefs.rowActions = enabled
            }
        }
        .listStyle(.bordered)
        .alternatingRowBackgrounds()
        .frame(height: CGFloat(RowAction.allCases.count) * 24 + 2)
    }

    private func set(_ a: RowAction, enabled: Bool) {
        var list = prefs.rowActions
        list.removeAll { $0 == a }
        if enabled { list.append(a) }
        prefs.rowActions = list
    }
}

/// Follow lists, then hidden users (bots by default) and hidden repos.
private struct SourcesTab: View {
    @Bindable var model: AppModel

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section("Follow") {
                TableEditor(title: "Users", items: $prefs.sources.followUsers, placeholder: "username",
                            normalize: { UserPrefs.normalize($0, kind: .users, hideList: false) },
                            onChange: model.sourcesChanged,
                            trailing: { login in
                                AnyView(TextField(model.displayName(for: login) ?? "Label",
                                                  text: Binding(get: { model.prefs.label(for: login) ?? "" },
                                                                set: { model.prefs.setLabel($0, for: login) }))
                                    .textFieldStyle(.plain).font(.callout).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing).frame(width: 140)
                                    .help("Section title instead of @\(login)"))
                            })
                TableEditor(title: "Repos", items: $prefs.sources.followRepos, placeholder: "owner/repo",
                            normalize: { UserPrefs.normalize($0, kind: .repos, hideList: false) }, onChange: model.sourcesChanged)
                TableEditor(title: "Orgs", items: $prefs.sources.followOrgs, placeholder: "org",
                            normalize: { UserPrefs.normalize($0, kind: .orgs, hideList: false) }, onChange: model.sourcesChanged)
                TableEditor(title: "Branches", items: $prefs.sources.followBranches, placeholder: "owner/repo@main  or  owner/repo@rc/*",
                            normalize: { UserPrefs.normalize($0, kind: .branches, hideList: false) }, onChange: model.sourcesChanged)
                Stepper("Commits shown per branch: \(prefs.branchCommits)", value: $prefs.branchCommits, in: 1...10)
                    .onChange(of: prefs.branchCommits) { _, _ in model.sourcesChanged() }
                Text("Every open PR from a followed user, repo, or org gets its own section. A followed branch shows its latest CI verdict (is main green?) and notifies when it goes red; raise the commit count to see the last few commits and which one broke it. A pattern like rc/* follows whichever matching branch has the newest commit, adds a section of PRs targeting it, and tells you when a new one is cut.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Hide") {
                TableEditor(title: "Users", items: $prefs.sources.hiddenUsers, placeholder: "username or name[bot]",
                            normalize: { UserPrefs.normalize($0, kind: .users, hideList: true) }, onChange: model.sourcesChanged)
                TableEditor(title: "Repos", items: $prefs.sources.hiddenRepos, placeholder: "owner/repo",
                            normalize: { UserPrefs.normalize($0, kind: .repos, hideList: true) }, onChange: model.sourcesChanged)
                LabeledContent("PRs") {
                    if model.prefs.sources.hiddenPRs.isEmpty {
                        Text("None. Right-click a PR → Hide this PR. Hidden repos are set here only.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.prefs.sources.hiddenPRs.sorted(by: { $0.value < $1.value }), id: \.key) { id, label in
                                HStack {
                                    Text(label).lineLimit(1).truncationMode(.tail)
                                    Spacer()
                                    Button { model.unhide(prID: id) } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.borderless).help("Show again")
                                }
                            }
                        }
                    }
                }
                Text("Hidden users, repos, and PRs are removed everywhere: list, dots, widget, notifications. A hidden PR drops off this list once it merges or closes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Recently merged", selection: $prefs.mergedDays) {
                    Text("Off").tag(0)
                    Text("Last 24 hours").tag(1)
                    Text("Last 7 days").tag(7)
                }
                .onChange(of: prefs.mergedDays) { _, _ in model.sourcesChanged() }
            } footer: {
                Text("Your merged PRs, collapsed. When checks run on the merge commit, a failure there lights the dots.")
            }
            Section("Watched PRs") {
                if model.prefs.watched.isEmpty {
                    Text("None. Press ⌘N in the popover to watch a PR by URL.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.prefs.watched) { ref in
                        HStack {
                            Text(ref.key)
                            Spacer()
                            Button { model.prefs.unwatch(ref); model.sourcesChanged() } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Stop watching")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// System Settings style: a bordered table with + / − under it. "+" adds an editable row;
/// Return commits (validated), Escape or an empty value discards it. "−" removes the selection.
private struct TableEditor: View {
    let title: String
    @Binding var items: [String]
    let placeholder: String
    let normalize: (String) -> String?
    var onChange: () -> Void = {}
    var trailing: ((String) -> AnyView)? = nil

    @State private var selection: String?
    @State private var draft: String?
    @FocusState private var draftFocused: Bool

    private var rowCount: Int { items.count + (draft == nil ? 0 : 1) }

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .leading, spacing: 4) {
                List(selection: $selection) {
                    ForEach(items, id: \.self) { item in
                        HStack {
                            Text(item)
                            Spacer()
                            if let trailing { trailing(item) }
                        }
                        .tag(item)
                    }
                    if draft != nil {
                        TextField(placeholder, text: Binding(get: { draft ?? "" }, set: { draft = $0 }))
                            .textFieldStyle(.plain)
                            .focused($draftFocused)
                            .onSubmit(commit)
                            .onExitCommand { draft = nil }
                            .onChange(of: draftFocused) { _, focused in if !focused { commit() } }
                    }
                }
                .listStyle(.bordered)
                .alternatingRowBackgrounds()
                .frame(height: CGFloat(max(2, min(rowCount, 6))) * 24 + 2)
                HStack(spacing: 0) {
                    Button { startDraft() } label: { Image(systemName: "plus").frame(width: 22, height: 18) }
                        .help("Add")
                    Divider().frame(height: 12)
                    Button { removeSelected() } label: { Image(systemName: "minus").frame(width: 22, height: 18) }
                        .disabled(selection == nil)
                        .help("Remove")
                }
                .buttonStyle(.borderless)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                .onDeleteCommand(perform: removeSelected)
            }
        }
        .labeledContentStyle(.automatic)
    }

    private func startDraft() {
        guard draft == nil else { draftFocused = true; return }
        draft = ""
        DispatchQueue.main.async { draftFocused = true }
    }

    private func commit() {
        guard let text = draft else { return }
        draft = nil
        guard let value = normalize(text) else {
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { NSSound.beep() }
            return
        }
        guard !items.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { return }
        items.append(value)
        selection = value
        onChange()
    }

    private func removeSelected() {
        guard let sel = selection else { return }
        items.removeAll { $0 == sel }
        selection = nil
        onChange()
    }
}
