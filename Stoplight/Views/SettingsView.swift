import SwiftUI
import ServiceManagement
import StoplightCore

/// US-008 + US-010/011 lists.
struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage(Prefs.showCount) private var showCount = false
    @AppStorage(Prefs.notifications) private var notifications = "all"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
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
            Section {
                Toggle("Show count in menu bar", isOn: $showCount)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section("Hidden repos") {
                if model.prefs.hiddenRepos.isEmpty {
                    Text("None. Right-click a PR to hide its repo.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.prefs.hiddenRepos.sorted(), id: \.self) { repo in
                        HStack {
                            Text(repo)
                            Spacer()
                            Button { model.unhide(repo: repo) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Show again")
                        }
                    }
                }
            }
            Section("Watching") {
                if model.prefs.watched.isEmpty {
                    Text("None. Press ⌘N in the popover to watch a PR by URL.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.prefs.watched) { ref in
                        HStack {
                            Text(ref.key)
                            Spacer()
                            Button { model.prefs.unwatch(ref) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Stop watching")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }
}
