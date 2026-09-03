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
        }
        .formStyle(.grouped)
    }
}

/// Three groups (Users, Repos, Orgs), each with a Follow list and an Ignore list. Plus watched PRs.
private struct SourcesTab: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            ForEach(UserPrefs.SourceKind.allCases) { kind in
                Section(kind.title) {
                    HStack(alignment: .top, spacing: 16) {
                        ListEditor(title: "Follow", items: model.prefs.sources[kind, .follow], placeholder: kind.placeholder,
                                   add: { edit(kind, .follow, add: $0) }, remove: { edit(kind, .follow, remove: $0) })
                        Divider()
                        ListEditor(title: "Ignore", items: model.prefs.sources[kind, .ignore], placeholder: kind.placeholder,
                                   add: { edit(kind, .ignore, add: $0) }, remove: { edit(kind, .ignore, remove: $0) })
                    }
                }
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
            Section {
                Text("Follow shows every open PR from that user, repo, or org in its own section. Ignore removes matching PRs everywhere: list, dots, widget, notifications.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func edit(_ kind: UserPrefs.SourceKind, _ list: UserPrefs.ListKind, add value: String) -> UserPrefs.AddResult {
        let r = model.prefs.add(value, to: kind, list: list)
        if r == .added { model.sourcesChanged() }
        return r
    }

    private func edit(_ kind: UserPrefs.SourceKind, _ list: UserPrefs.ListKind, remove value: String) {
        model.prefs.remove(value, from: kind, list: list)
        model.sourcesChanged()
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
