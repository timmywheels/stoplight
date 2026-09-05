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
            Section("Account") {
                switch model.auth {
                case .signedIn(let login, let source):
                    LabeledContent("Signed in as", value: "@\(login)")
                    LabeledContent("Source", value: source.rawValue)
                    Button("Sign out") { model.signOut() }
                default:
                    Text("Not signed in").foregroundStyle(.secondary)
                }
            }
            Section("Notifications") {
                Picker("Notify me", selection: $notifications) {
                    Text("On fail and all-green").tag("all")
                    Text("On fail only").tag("failOnly")
                    Text("Never").tag("off")
                }
                .pickerStyle(.radioGroup)
            }
            Section("Row buttons") {
                RowActionsEditor(prefs: prefs)
                Text("The circles in an expanded PR. Check to show, drag to reorder. Buttons that don't apply to a row (no Actions run, nothing to fix) hide themselves.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Merged") {
                Picker("Show recently merged", selection: $prefs.mergedDays) {
                    Text("Off").tag(0)
                    Text("Last 24 hours").tag(1)
                    Text("Last 7 days").tag(7)
                }
                .onChange(of: prefs.mergedDays) { _, _ in model.sourcesChanged() }
                Text("A collapsed section of your merged PRs. When checks run on the merge commit (deploys on main), their status shows there and a failure lights the dots.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Toggle("Dark housing behind the dots", isOn: $prefs.housing)
                Toggle("Show count in menu bar", isOn: $prefs.showCount)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section {
                HStack {
                    Text("Guided tour").foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Again") { model.prefs.tourSeen = false; model.openPanel?() }
                }
            }
            Section("Legend") {
                LegendRow("Failing. At least one check failed.") { StatusDot(state: .failure) }
                LegendRow("Running. Checks still in progress.") { StatusDot(state: .pending) }
                LegendRow("Passed. Every check green, skipped, or neutral.") { StatusDot(state: .success) }
                LegendRow("No checks configured.") { StatusDot(state: .none) }
                LegendRow("Merged. The branch badge next to it is colored by the base branch's current CI state.") { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.purple) }
                LegendRow("Hollow dot: draft. Drafts never light the menu bar or notify.") { StatusDot(state: .success, hollow: true) }
                LegendRow("Stacked on the PR above it. Right-click to copy the whole stack.") { Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.tertiary) }
                LegendRow("In the merge queue at that position. \"Queue: blocked\" means GitHub can't merge it.") { legendTag("Queue #2", .blue) }
                LegendRow("Based on a branch whose PR isn't in view.") { legendTag("on feat/x", .secondary) }
                LegendRow("Click a PR to open it on GitHub. Double-click or ⌘-click to expand it: description, failing checks, and buttons for Open, Copy URL, Share, Pin, and Fix with your agent. Right-click for the rest.") { HStack(spacing: 6) { Image(systemName: "arrow.up.right"); Image(systemName: "doc.on.doc"); Image(systemName: "square.and.arrow.up"); Image(systemName: "pin"); Image(systemName: "sparkles") }.font(.caption).foregroundStyle(.secondary) }
                LegendRow("Footer dots filter the list by status. Click to toggle, combine freely.") { Text("● 3").font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                HStack {
                    Text("Stoplight \(model.updater.currentVersion)").foregroundStyle(.secondary)
                    Spacer()
                    updateControl
                    Button("Quit Stoplight") { NSApp.terminate(nil) }.keyboardShortcut("q")
                }
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
                Text("Every open PR from a followed user, repo, or org gets its own section. A followed branch shows the latest CI verdict on that branch (is main green?) and notifies when it goes red. A pattern like rc/* follows whichever matching branch has the newest commit, adds a section of PRs targeting it, and tells you when a new one is cut.")
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
