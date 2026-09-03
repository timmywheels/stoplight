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
    /// Keys of events already delivered, per (PR, sha, kind). Pruned when a PR leaves the list (US-006).
    private var sentEvents: Set<String> = []
    /// Watched refs seen closed/merged once; removed on the next cycle (US-011).
    private var closedSeen: Set<String> = []

    // MARK: Derived lists (US-010, US-012, US-013)

    struct Section: Identifiable {
        let title: String
        let prs: [PullRequest]
        var id: String { title }
    }

    /// Everything visible, deduped, ignore rules applied. Source of truth for dots, widget, notifications.
    var all: [PullRequest] {
        var seen = Set<String>()
        var out: [PullRequest] = []
        for pr in mine + watched + followed.flatMap(\.prs) where seen.insert(pr.id).inserted {
            out.append(pr)
        }
        return Filters.visible(out, ignore: prefs.ignoreRules)
    }

    /// Popover sections in order: Pinned, Mine, Watching, then one per followed source.
    /// A PR appears once, in the first section that claims it.
    var sections: [Section] {
        let allowed = Set(all.map(\.id))
        var claimed = Set<String>()
        func take(_ prs: [PullRequest], pinnedOnly: Bool = false, skipPinned: Bool = true) -> [PullRequest] {
            let picked = prs.filter { pr in
                guard allowed.contains(pr.id), !claimed.contains(pr.id) else { return false }
                let isPinned = prefs.pinned.contains(pr.id)
                return pinnedOnly ? isPinned : (!skipPinned || !isPinned)
            }
            picked.forEach { claimed.insert($0.id) }
            return Rollup.sorted(picked)
        }
        var out: [Section] = []
        out.append(Section(title: "Pinned", prs: take(all, pinnedOnly: true)))
        out.append(Section(title: "Mine", prs: take(mine)))
        out.append(Section(title: "Watching", prs: take(watched)))
        for f in followed { out.append(Section(title: f.query.title, prs: take(f.prs))) }
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

    // MARK: Lifecycle

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.signIn()
            while !Task.isCancelled {
                await self?.refresh()
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

    private func publishSnapshot() {
        try? SharedStore.save(all, pinnedIDs: Array(prefs.pinned))
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

    /// Pins on PRs that no longer exist are dropped silently (US-012).
    private func prunePins() {
        let live = Set((mine + watched + followed.flatMap(\.prs)).map(\.id))
        let stale = prefs.pinned.subtracting(live)
        if !stale.isEmpty { prefs.pinned.subtract(stale) }
    }

    // MARK: User actions

    func ignore(_ value: String, kind: UserPrefs.SourceKind) {
        prefs.add(value, to: kind, list: .ignore)
        publishSnapshot()
    }

    func follow(user: String) {
        prefs.add(user, to: .users, list: .follow)
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
