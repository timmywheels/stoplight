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
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
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

/// Follow lists, then the two exclusions that matter: hidden repos and bots.
private struct SourcesTab: View {
    @Bindable var model: AppModel

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section("Follow") {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(UserPrefs.SourceKind.allCases) { kind in
                        ListEditor(title: kind.title, items: model.prefs.sources[follow: kind], placeholder: kind.placeholder,
                                   add: { r in let res = model.prefs.follow(r, kind: kind); if res == .added { model.sourcesChanged() }; return res },
                                   remove: { model.prefs.unfollow($0, kind: kind); model.sourcesChanged() })
                        if kind != .orgs { Divider() }
                    }
                }
                Text("Every open PR from a followed user, repo, or org gets its own section in the popover.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Hide") {
                ListEditor(title: "Repos", items: model.prefs.sources.hiddenRepos, placeholder: "owner/repo",
                           add: { r in let res = model.prefs.hide(repo: r); if res == .added { model.sourcesChanged() }; return res },
                           remove: { model.prefs.unhide(repo: $0); model.sourcesChanged() })
                Toggle("Hide bot PRs (dependabot, renovate, …)", isOn: $prefs.sources.hideBots)
                    .onChange(of: prefs.sources.hideBots) { _, _ in model.sourcesChanged() }
                Text("Hidden repos and bots are removed everywhere: list, dots, widget, notifications. Right-click a PR to hide its repo.")
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

/// A short list with a remove button per row and an add field at the bottom.
private struct ListEditor: View {
    let title: String
    let items: [String]
    let placeholder: String
    let add: (String) -> UserPrefs.AddResult
    let remove: (String) -> Void
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(items, id: \.self) { item in
                HStack(spacing: 4) {
                    Text(item).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button { remove(item) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 4) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button { submit() } label: { Image(systemName: "plus.circle") }
                    .buttonStyle(.borderless)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func submit() {
        switch add(text) {
        case .added: text = ""; error = nil
        case .duplicate: error = "Already listed"
        case .invalid: error = "Not a valid \(placeholder)"
        }
    }
}
