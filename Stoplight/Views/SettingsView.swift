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
            Section("Legend") {
                LegendRow("Failing. At least one check failed.") { StatusDot(state: .failure) }
                LegendRow("Running. Checks still in progress.") { StatusDot(state: .pending) }
                LegendRow("Passed. Every check green, skipped, or neutral.") { StatusDot(state: .success) }
                LegendRow("No checks configured.") { StatusDot(state: .none) }
                LegendRow("Hollow dot: draft. Drafts never light the menu bar or notify.") { StatusDot(state: .success, hollow: true) }
                LegendRow("Stacked on the PR above it. Right-click to copy the whole stack.") { Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.tertiary) }
                LegendRow("In the merge queue at that position. \"Queue: blocked\" means GitHub can't merge it.") { legendTag("Queue #2", .blue) }
                LegendRow("Based on a branch whose PR isn't in view.") { legendTag("on feat/x", .secondary) }
                LegendRow("On hover: open on GitHub, copy URL, share. Share copies the PR title as a link: a hyperlink in Slack, Markdown in GitHub. Hover the title for the description. Right-click for everything else.") { HStack(spacing: 8) { Image(systemName: "arrow.up.right"); Image(systemName: "doc.on.doc"); Image(systemName: "square.and.arrow.up") }.font(.caption).foregroundStyle(.secondary) }
                LegendRow("Footer dots filter the list by status. Click to toggle, combine freely.") { Text("● 3").font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                HStack {
                    Text("Stoplight \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                        .foregroundStyle(.secondary)
                    Spacer()
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
                Text("Every open PR from a followed user, repo, or org gets its own section in the popover.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Hide") {
                TableEditor(title: "Users", items: $prefs.sources.hiddenUsers, placeholder: "username or name[bot]",
                            normalize: { UserPrefs.normalize($0, kind: .users, hideList: true) }, onChange: model.sourcesChanged)
                TableEditor(title: "Repos", items: $prefs.sources.hiddenRepos, placeholder: "owner/repo",
                            normalize: { UserPrefs.normalize($0, kind: .repos, hideList: true) }, onChange: model.sourcesChanged)
                Text("Hidden users and repos are removed everywhere: list, dots, widget, notifications. Right-click a PR to hide its repo.")
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
