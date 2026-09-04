import Foundation
import Observation
import StoplightCore

@MainActor
@Observable
final class AppModel {
    enum AuthState: Equatable {
        case unknown
        case signedOut
        case signedIn(login: String, source: TokenSource.Kind)
        case failed(String)
    }

    let prefs = UserPrefs()

    /// Raw fetch results, unfiltered.
    private(set) var mine: [PullRequest] = []
    private(set) var watched: [PullRequest] = []
    /// Followed users/repos/orgs, in `prefs.followQueries` order.
    private(set) var followed: [(query: PRQuery, prs: [PullRequest])] = []
    private(set) var lastRefresh: Date?
    private(set) var lastError: String?
    private(set) var auth: AuthState = .unknown
    private(set) var isRefreshing = false
    private(set) var login: String?
    /// Extra diameter for the green dot during the one-shot pop (US-004).
    private(set) var bob: CGFloat = 0
    private var lastAggregate: CIState?

    private var provider: GitHubProvider?
    private var loop: Task<Void, Never>?
    private let notifier = NotificationService()
    private let server = SnapshotServer()
    let updater = Updater()
    /// Keys of events already delivered, per (PR, sha, kind). Pruned when a PR leaves the list (US-006).
    private var sentEvents: Set<String> = []
    /// Watched refs seen closed/merged once; removed on the next cycle (US-011).
    private var closedSeen: Set<String> = []

    // MARK: Derived lists (US-010, US-012, US-013)

    struct Section: Identifiable {
        /// Stable key for collapse state: "Pinned", "Mine", "Watching", or the query title ("@login", "owner/repo", "org").
        let id: String
        let title: String
        let prs: [PullRequest]
        /// The followed source this section came from; nil for Pinned / Mine / Watching.
        var query: PRQuery? = nil

        /// Rows drop whatever the header already says (US-005: no duplicated data).
        var hidesAuthor: Bool { if case .author = query { return true }; return false }
        func refLabel(for pr: PullRequest) -> String {
            switch query {
            case .repo: return "#\(pr.number)"
            case .org(let o) where pr.repo.lowercased().hasPrefix(o.lowercased() + "/"):
                return "\(pr.repo.dropFirst(o.count + 1)) #\(pr.number)"
            default: return pr.shortRef
            }
        }
    }

    /// Popover status filter (US-018). Empty = show everything. Session-only, not persisted.
    var statusFilter: Set<CIState> = []
    func toggleFilter(_ state: CIState) {
        if statusFilter.contains(state) { statusFilter.remove(state) } else { statusFilter.insert(state) }
    }
    /// Counts per state across everything visible, for the filter buttons.
    func count(_ state: CIState) -> Int { all.filter { $0.state == state }.count }

    /// login (lowercased) → display name, for followed users (US-013).
    private(set) var displayNames: [String: String] = [:]
    private var namesFetchedFor: Set<String> = []

    func displayName(for login: String) -> String? { displayNames[login.lowercased()] }

    /// Everything visible, deduped, ignore rules applied. Source of truth for dots, widget, notifications.
    var all: [PullRequest] {
        var seen = Set<String>()
        var out: [PullRequest] = []
        for pr in mine + watched + followed.flatMap(\.prs) where seen.insert(pr.id).inserted {
            out.append(pr)
        }
        let hidden = prefs.sources.hiddenPRs
        return Filters.visible(out, ignore: prefs.ignoreRules).filter { hidden[$0.id] == nil }
    }

    /// Popover sections in order: Pinned, Mine, Watching, then one per followed source.
    /// A PR appears once, in the first section that claims it.
    var sections: [Section] {
        let allowed = Set(all.map(\.id))
        var claimed = Set<String>()
        let filter = statusFilter
        func take(_ prs: [PullRequest], pinnedOnly: Bool = false, skipPinned: Bool = true) -> [PullRequest] {
            let picked = prs.filter { pr in
                guard allowed.contains(pr.id), !claimed.contains(pr.id) else { return false }
                guard filter.isEmpty || filter.contains(pr.state) else { return false }
                let isPinned = prefs.pinned.contains(pr.id)
                return pinnedOnly ? isPinned : (!skipPinned || !isPinned)
            }
            picked.forEach { claimed.insert($0.id) }
            return Rollup.sorted(picked)
        }
        var out: [Section] = []
        out.append(Section(id: "Pinned", title: "Pinned", prs: take(all, pinnedOnly: true)))
        out.append(Section(id: "Mine", title: "Mine", prs: take(mine)))
        out.append(Section(id: "Watching", title: "Watching", prs: take(watched)))
        for f in followed {
            var title = f.query.title
            if case .author(let login) = f.query, let name = prefs.label(for: login) ?? displayName(for: login) { title = name }
            out.append(Section(id: f.query.title, title: title, prs: take(f.prs), query: f.query))
        }
        return out.filter { !$0.prs.isEmpty }
    }
    var isEmpty: Bool { all.isEmpty }

    var aggregate: CIState { Rollup.aggregate(all) }
    var presence: StatusPresence { StatusPresence(all) }
    var badgeCount: Int? {
        guard prefs.showCount else { return nil }
        let n = all.filter { !$0.isDraft && $0.state != .success && $0.state != .none }.count
        return n > 0 ? n : nil
    }
    func isWatched(_ pr: PullRequest) -> Bool { pr.ref.map { prefs.watched.contains($0) } ?? false }
    func isMine(_ pr: PullRequest) -> Bool { login.map { $0.caseInsensitiveCompare(pr.author) == .orderedSame } ?? false }
    func isPinned(_ pr: PullRequest) -> Bool { prefs.pinned.contains(pr.id) }
    func displayTitle(_ pr: PullRequest) -> String { prefs.alias(for: pr.id) ?? pr.title }

    // MARK: Lifecycle

    func start() {
        guard loop == nil else { return }
        server.start()
        loop = Task { [weak self] in
            await self?.signIn()
            while !Task.isCancelled {
                await self?.refresh()
                await self?.updater.checkIfDue()
                let interval = self?.nextInterval ?? 60
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// US-003 adaptive polling.
    private var nextInterval: TimeInterval {
        if let rl = GitHubProvider.lastRateLimit, rl.remaining < 100 { return 300 }
        if all.isEmpty { return 300 }
        if all.contains(where: { $0.state == .pending }) { return 20 }
        return 60
    }

    // MARK: Auth (US-001)

    func signIn() async {
        guard let found = TokenSource.resolve() else {
            auth = .signedOut
            provider = nil
            return
        }
        let p = GitHubProvider(token: found.token)
        do {
            let login = try await p.viewerLogin()
            provider = p
            self.login = login
            auth = .signedIn(login: login, source: found.kind)
        } catch {
            provider = nil
            auth = .failed(error.localizedDescription)
        }
    }

    func signIn(pastedToken: String) async {
        TokenSource.storeInKeychain(pastedToken)
        await signIn()
        await refresh()
    }

    func signOut() {
        TokenSource.clearKeychain()
        provider = nil
        mine = []
        watched = []
        followed = []
        auth = .signedOut
        SharedStore.clear()
        server.update(Data("{}".utf8))
        WidgetBridge.reload()
    }

    // MARK: Fetch (US-002, US-011)

    func refresh() async {
        guard let provider, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let refs = prefs.watched
            let queries = [PRQuery.authored] + prefs.followQueries
            async let searchTask = provider.fetchPullRequests(queries: queries)
            async let watchedTask = provider.fetchPullRequests(refs: refs)
            let (results, freshWatched) = try await (searchTask, watchedTask)
            let previous = all
            mine = results.first ?? []
            followed = Array(zip(queries.dropFirst(), results.dropFirst()))
            watched = freshWatched
            lastRefresh = .now
            lastError = nil
            pruneClosedWatches()
            prunePins()
            publishSnapshot()
            await notify(previous: previous)
            bobIfJustTurnedGreen()
            await resolveDisplayNames(provider)
        } catch {
            // Keep last good data on screen; surface the error as "stale" (US-002).
            lastError = error.localizedDescription
            if case GitHubProvider.Error.unauthorized = error {
                auth = .failed("Token rejected")
                self.provider = nil
            }
        }
    }

    // MARK: Head-bob (US-004)

    /// One pop, ~0.4s, only on the transition into all-green. Never loops.
    private func bobIfJustTurnedGreen() {
        let now = aggregate
        defer { lastAggregate = now }
        guard now == .success, let last = lastAggregate, last != .success else { return }
        Task { @MainActor in
            let frames = 12
            for i in 1...frames {
                bob = 3.0 * sin(Double(i) / Double(frames) * .pi)
                try? await Task.sleep(for: .milliseconds(33))
            }
            bob = 0
        }
    }

    // MARK: Notifications (US-006)

    private func notify(previous: [PullRequest]) async {
        await notifier.requestAuthorizationIfNeeded()
        let current = all
        let events = Transitions.events(previous: previous, current: current, mode: NotificationService.mode)
            .filter { !sentEvents.contains($0.key) }
        for e in events {
            sentEvents.insert(e.key)
            await notifier.post(e)
        }
        // Drop keys for PRs that are gone so the set can't grow forever.
        let live = Set(current.map(\.id))
        sentEvents = sentEvents.filter { key in live.contains(String(key.split(separator: "|")[0])) }
    }

    /// One extra request, only when the followed-user set changes.
    private func resolveDisplayNames(_ provider: GitHubProvider) async {
        let wanted = Set(prefs.sources.followUsers.map { $0.lowercased() })
        let missing = wanted.subtracting(namesFetchedFor)
        guard !missing.isEmpty else { return }
        namesFetchedFor.formUnion(missing)
        if let names = try? await provider.fetchDisplayNames(logins: Array(missing)) {
            displayNames.merge(names) { _, new in new }
        }
    }

    private func publishSnapshot() {
        guard let data = try? SharedStore.encode(all, pinnedIDs: Array(prefs.pinned)) else { return }
        server.update(data)
        SharedStore.save(data)
        WidgetBridge.reload()
    }

    /// A watched PR that is merged/closed stays one cycle (with its tag), then drops off.
    private func pruneClosedWatches() {
        for pr in watched where pr.status != .open {
            guard let ref = pr.ref else { continue }
            if closedSeen.contains(ref.key) {
                prefs.unwatch(ref)
                closedSeen.remove(ref.key)
            } else {
                closedSeen.insert(ref.key)
            }
        }
    }

    /// Pins and nicknames on PRs that no longer exist are dropped silently (US-012, US-019).
    private func prunePins() {
        let live = Set((mine + watched + followed.flatMap(\.prs)).map(\.id))
        let stale = prefs.pinned.subtracting(live)
        if !stale.isEmpty { prefs.pinned.subtract(stale) }
        let staleAliases = Set(prefs.sources.prAliases.keys).subtracting(live)
        for id in staleAliases { prefs.sources.prAliases[id] = nil }
        // A hidden PR that merged or closed is gone for good; drop it so the Settings list stays honest.
        let staleHidden = Set(prefs.sources.hiddenPRs.keys).subtracting(live)
        for id in staleHidden { prefs.sources.hiddenPRs[id] = nil }
    }

    // MARK: User actions

    func hide(repo: String) {
        prefs.hide(repo: repo)
        publishSnapshot()
    }

    func hide(pr: PullRequest) {
        prefs.hide(pr: pr)
        publishSnapshot()
    }

    func unhide(prID: String) {
        prefs.unhide(prID: prID)
        publishSnapshot()
    }

    func follow(user: String) {
        prefs.follow(user, kind: .users)
        Task { await refresh() }
    }

    /// Settings edits call this so the dots and widget update without waiting for the next poll.
    func sourcesChanged() {
        Task { await refresh() }
    }

    func togglePin(_ pr: PullRequest) {
        prefs.togglePin(pr.id)
        publishSnapshot()
    }

    enum WatchResult { case added, alreadyWatched, invalid }

    func watch(urlString: String) -> WatchResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let ref = PRRef(url: url) else { return .invalid }
        guard prefs.watch(ref) else { return .alreadyWatched }
        Task { await refresh() }
        return .added
    }

    func unwatch(_ pr: PullRequest) {
        guard let ref = pr.ref else { return }
        prefs.unwatch(ref)
        watched.removeAll { $0.id == pr.id }
        publishSnapshot()
    }
}

enum Prefs {
    static let showCount = "showCountInMenuBar"
    static let housing = "menuBarHousing"
    static let notifications = "notificationMode"  // all | failOnly | off
}
