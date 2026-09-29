import SwiftUI
import StoplightCore

/// When Stoplight speaks up: CI changes, plus reviews and comments, minus the people and bots you mute.
struct NotificationsTab: View {
    @Bindable var model: AppModel
    @AppStorage(Prefs.notifications) private var notifications = "all"
    @State private var draft = ""
    @State private var adding = false
    @State private var problem: String?
    @FocusState private var draftFocused: Bool

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section("Checks") {
                Picker(selection: $notifications) {
                    Text("When a PR fails or turns all-passing").tag("all")
                    Text("Only when a PR fails").tag("failOnly")
                    Text("Never").tag("off")
                } label: {
                    InfoLabel("Notify me", "Fires when a PR changes state, not on every refresh. A PR that stays red stays quiet.")
                }
                .pickerStyle(.radioGroup)
            }

            Section {
                Toggle(isOn: $prefs.notifyReviews) {
                    InfoLabel("New reviews", "Someone approves, requests changes, or leaves a review with a summary. Changes requested makes a sound.")
                }
                Toggle(isOn: $prefs.notifyComments) {
                    InfoLabel("New comments", "On the conversation and on lines of code. Several at once arrive as one notification.")
                }
                Picker(selection: $prefs.notifyActivityOn) {
                    ForEach(UserPrefs.ActivityScope.allCases) { Text($0.title).tag($0) }
                } label: {
                    InfoLabel("On", "Your own pull requests, or every one Stoplight shows you (people and repos you follow, PRs you watch).")
                }
                .disabled(!prefs.notifyReviews && !prefs.notifyComments)
            } header: {
                Text("Reviews and comments")
            } footer: {
                Text(notifications == "off" ? "Notifications are off above, so these are too."
                     : "Your own comments never notify you. Clicking a notification opens the comment on GitHub.")
            }
            .disabled(notifications == "off")

            Section {
                Toggle(isOn: $prefs.ignoreBotActivity) {
                    InfoLabel("Ignore bots", "Anything GitHub marks as an app (Copilot, CodeRabbit, Vercel, Dependabot…) and any account ending in [bot].")
                }
                VStack(alignment: .leading, spacing: 6) {
                    BoxList(items: prefs.mutedAuthors.map(Muted.init), visibleRows: 6,
                            draft: adding ? { AnyView(draftRow) } : nil) { m in
                        HStack(spacing: 7) {
                            Image(systemName: m.login.lowercased().hasSuffix("[bot]") ? "gearshape" : "person").font(.caption)
                                .foregroundStyle(.secondary).frame(width: 14)
                            Text(m.login).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            RowRemoveButton(help: "Hear from \(m.login) again") { prefs.mutedAuthors.removeAll { $0 == m.login } }
                        }
                    }
                    HStack(spacing: 10) {
                        Button { adding = true; draftFocused = true } label: { Label("Add", systemImage: "plus") }
                            .buttonStyle(.borderless)
                        let recent = suggestions
                        if !recent.isEmpty {
                            Menu("Recently commenting") {
                                ForEach(recent, id: \.self) { login in Button(login) { prefs.mute(login) } }
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("People and bots who commented on the PRs Stoplight shows. Pick one to mute it.")
                        }
                        if let problem { Text(problem).font(.caption).foregroundStyle(.secondary) }
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("Mute")
            } footer: {
                Text("Reviews and comments from these never notify you. Their PRs still show, and their checks still count.")
            }
            .disabled(notifications == "off" || (!prefs.notifyReviews && !prefs.notifyComments))
        }
        .formStyle(.grouped)
    }

    private struct Muted: Identifiable { let login: String; var id: String { login } }

    /// Who commented lately and isn't muted (or you), bots first: they're the usual noise.
    private var suggestions: [String] {
        let me = model.login?.lowercased()
        let muted = Set(model.prefs.mutedAuthors.map { $0.lowercased() })
        var seen: [String: Bool] = [:]
        for pr in model.all { for a in pr.activity { seen[a.author, default: false] = seen[a.author, default: false] || a.isBot } }
        return seen.keys.filter { $0.lowercased() != me && !muted.contains($0.lowercased()) }
            .sorted { (seen[$0]! ? 0 : 1, $0.lowercased()) < (seen[$1]! ? 0 : 1, $1.lowercased()) }
            .prefix(20).map { seen[$0]! ? "\($0)[bot]" : $0 }
    }

    private var draftRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "person").font(.caption).foregroundStyle(.secondary).frame(width: 14)
            TextField("", text: $draft, prompt: Text("username or app[bot]"))
                .textFieldStyle(.plain)
                .labelsHidden()
                .focused($draftFocused)
                .onSubmit(commit)
                .onExitCommand { draft = ""; adding = false }
                .onChange(of: draftFocused) { _, focused in if !focused { commit() } }
        }
    }

    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        defer { draft = ""; adding = false }
        guard !text.isEmpty else { problem = nil; return }
        switch model.prefs.mute(text) {
        case .added: problem = nil
        case .duplicate: problem = "Already muted."
        case .invalid: problem = "That isn't a GitHub username."
        }
    }
}
