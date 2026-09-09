import SwiftUI
import StoplightCore

/// Settings → Sources (US-013). One list of everything you follow and one of everything you hide,
/// each row saying what it is, instead of six little tables stacked on top of each other.
struct SourcesTab: View {
    @Bindable var model: AppModel

    /// What a row is, which decides its glyph, how a new one is validated, and how it's removed.
    enum Kind: String, Identifiable, CaseIterable {
        case user, org, repo, branch, pr
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .user: "person"
            case .org: "building.2"
            case .repo: "shippingbox"
            case .branch: "arrow.triangle.branch"
            case .pr: "arrow.triangle.pull"
            }
        }
        var addTitle: String {
            switch self {
            case .user: "User…"
            case .org: "Organization…"
            case .repo: "Repository…"
            case .branch: "Branch…"
            case .pr: "Pull Request…"
            }
        }
        var prompt: String {
            switch self {
            case .user: "username"
            case .org: "org"
            case .repo: "owner/repo"
            case .branch: "owner/repo@main   or   owner/repo@rc/*"
            case .pr: "https://github.com/owner/repo/pull/123"
            }
        }
    }

    struct Row: Identifiable {
        let kind: Kind
        /// What removal keys off: a login, a slug, a branch spec, a PR ref key, or a hidden PR's id.
        let key: String
        /// What the row shows. Same as `key` except for hidden PRs, which show their title.
        let title: String
        var id: String { "\(kind.rawValue):\(key)" }
    }

    private enum ListID { case following, hidden }

    @State private var draftList: ListID?
    @State private var draftKind: Kind = .user
    @State private var draftText = ""
    @FocusState private var draftFocused: Bool

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section {
                list(.following, rows: followingRows, kinds: Kind.allCases)
            } header: {
                Text("Following")
            } footer: {
                Text("Every open PR from a user, org, or repo you follow gets its own section. A branch shows its own CI verdict instead: is main green? A pattern like rc/* follows whichever match has the newest commit.")
            }

            Section {
                list(.hidden, rows: hiddenRows, kinds: [.user, .repo])
            } header: {
                Text("Hidden")
            } footer: {
                Text("Gone everywhere: list, dots, widget, notifications. Bots are hidden by default. To hide one PR, right-click it in the panel; it drops off this list once it merges or closes.")
            }

            Section {
                Picker(selection: $prefs.mergedDays) {
                    Text("Off").tag(0)
                    Text("Last 24 hours").tag(1)
                    Text("Last 7 days").tag(7)
                } label: {
                    InfoLabel("Recently merged",
                              "Keeps your merged PRs around a while, so a red merge commit still reaches you.")
                }
                .onChange(of: prefs.mergedDays) { _, _ in model.sourcesChanged() }

                Stepper(value: $prefs.branchCommits, in: 1...10) {
                    InfoLabel("Commits shown per branch: \(prefs.branchCommits)",
                              "How many recent commits each followed branch lists, so you can see which one broke it.")
                }
                .onChange(of: prefs.branchCommits) { _, _ in model.sourcesChanged() }
            } header: {
                Text("Options")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: The two lists

    @ViewBuilder
    private func list(_ id: ListID, rows: [Row], kinds: [Kind]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            BoxList(items: rows, visibleRows: 8,
                    draft: draftList == id ? { AnyView(draftRow) } : nil) { row in
                HStack(spacing: 7) {
                    Image(systemName: row.kind.symbol).font(.caption)
                        .foregroundStyle(.secondary).frame(width: 14)
                    Text(row.title).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    if id == .following, row.kind == .user { aliasField(for: row.key) }
                    RowRemoveButton(help: "Remove") { remove(row, from: id) }
                }
            }
            Menu {
                ForEach(kinds) { kind in
                    Button { startDraft(id, kind: kind) } label: { Label(kind.addTitle, systemImage: kind.symbol) }
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .controlSize(.small)
        }
    }

    private var draftRow: some View {
        HStack(spacing: 7) {
            Image(systemName: draftKind.symbol).font(.caption).foregroundStyle(.secondary).frame(width: 14)
            TextField("", text: $draftText, prompt: Text(draftKind.prompt))
                .textFieldStyle(.plain)
                .labelsHidden()
                .focused($draftFocused)
                .onSubmit(commitDraft)
                .onExitCommand { cancelDraft() }
                .onChange(of: draftFocused) { _, focused in if !focused { commitDraft() } }
        }
    }

    /// A followed user can carry a nicer section title than @login.
    private func aliasField(for login: String) -> some View {
        TextField(model.displayName(for: login) ?? "Label",
                  text: Binding(get: { model.prefs.label(for: login) ?? "" },
                                set: { model.prefs.setLabel($0, for: login) }))
            .textFieldStyle(.plain)
            .font(.callout).foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .frame(width: 130)
            .help("Section title instead of @\(login)")
    }

    // MARK: Rows

    private var followingRows: [Row] {
        let s = model.prefs.sources
        return s.followUsers.map { Row(kind: .user, key: $0, title: $0) }
            + s.followOrgs.map { Row(kind: .org, key: $0, title: $0) }
            + s.followRepos.map { Row(kind: .repo, key: $0, title: $0) }
            + s.followBranches.map { Row(kind: .branch, key: $0, title: $0) }
            + model.prefs.watched.map { Row(kind: .pr, key: $0.key, title: $0.key) }
    }

    private var hiddenRows: [Row] {
        let s = model.prefs.sources
        return s.hiddenUsers.map { Row(kind: .user, key: $0, title: $0) }
            + s.hiddenRepos.map { Row(kind: .repo, key: $0, title: $0) }
            + s.hiddenPRs.sorted { $0.value < $1.value }.map { Row(kind: .pr, key: $0.key, title: $0.value) }
    }

    // MARK: Editing

    private func startDraft(_ id: ListID, kind: Kind) {
        draftList = id
        draftKind = kind
        draftText = ""
        DispatchQueue.main.async { draftFocused = true }
    }

    private func cancelDraft() {
        draftList = nil
        draftText = ""
    }

    private func commitDraft() {
        guard let id = draftList else { return }
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = draftKind
        cancelDraft()
        guard !text.isEmpty else { return }
        if add(text, kind: kind, to: id) {
            model.sourcesChanged()
        } else {
            NSSound.beep()
        }
    }

    /// False means the value didn't validate. A duplicate is quietly accepted as a no-op.
    private func add(_ text: String, kind: Kind, to id: ListID) -> Bool {
        let prefs = model.prefs
        switch (id, kind) {
        case (.following, .user): return prefs.follow(text, kind: .users) != .invalid
        case (.following, .org): return prefs.follow(text, kind: .orgs) != .invalid
        case (.following, .repo): return prefs.follow(text, kind: .repos) != .invalid
        case (.following, .branch): return prefs.follow(text, kind: .branches) != .invalid
        case (.following, .pr): return model.watch(urlString: text) != .invalid
        case (.hidden, .user):
            guard let value = UserPrefs.normalize(text, kind: .users, hideList: true) else { return false }
            if !prefs.sources.hiddenUsers.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
                prefs.sources.hiddenUsers.append(value)
            }
            return true
        case (.hidden, .repo): return prefs.hide(repo: text) != .invalid
        // The menu never offers these, so nothing to add.
        case (.hidden, .org), (.hidden, .branch), (.hidden, .pr): return false
        }
    }

    private func remove(_ row: Row, from id: ListID) {
        let prefs = model.prefs
        switch (id, row.kind) {
        case (.following, .user): prefs.unfollow(row.key, kind: .users)
        case (.following, .org): prefs.unfollow(row.key, kind: .orgs)
        case (.following, .repo): prefs.unfollow(row.key, kind: .repos)
        case (.following, .branch): prefs.unfollow(row.key, kind: .branches)
        case (.following, .pr):
            if let ref = prefs.watched.first(where: { $0.key == row.key }) { prefs.unwatch(ref) }
        case (.hidden, .user): prefs.sources.hiddenUsers.removeAll { $0 == row.key }
        case (.hidden, .repo): prefs.unhide(repo: row.key)
        case (.hidden, .pr): model.unhide(prID: row.key)
        case (.hidden, .org), (.hidden, .branch): break
        }
        model.sourcesChanged()
    }
}
