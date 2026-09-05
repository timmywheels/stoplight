import AppKit
import Foundation
import Observation
import StoplightCore

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    /// Set by the status panel controller so views (Settings) can pop the panel open.
    var openPanel: (() -> Void)?
    /// Natural height of the list content, reported by the view so the panel can shrink to fit (US-027).
    var contentHeight: CGFloat = 0
    /// Pinned: stays open above other windows, ignores click-outside, keeps wherever you dragged it.
    var pinnedPanel = false

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
    /// My PRs merged within `prefs.mergedDays` (US-022). Their `state` is the merge commit's checks.
    private(set) var merged: [PullRequest] = []
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
        /// Stable key for collapse state: "Pinned", "Mine" (shown as "My PRs"), "Watching", or the query title ("@login", "owner/repo", "org").
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

    /// The one expanded row (US-021). Accordion: expanding another collapses this one. Session-only.
    var expandedID: String?
    func toggleExpanded(_ id: String) { expandedID = expandedID == id ? nil : id }

    // MARK: Keyboard (US-026)

    /// Keyboard selection. Session-only. Nil until the user touches the arrow keys.
    var selectedID: String?
    var showHotkeys = false
    /// Tab focus inside the expanded row: index into its button row. nil = none.
    var focusedButton: Int?
    /// The expanded row reports how many buttons it has, so Tab can wrap.
    var expandedButtonCount = 0
    /// Bumped on ↩ when a button is focused; the expanded row performs the focused action.
    var activateFocused = 0

    /// Row ids in display order, skipping collapsed sections.
    var visibleRowIDs: [String] {
        sections.flatMap { sec in prefs.collapsedSections.contains(sec.id) ? [] : Stacks.layout(sec.prs).map(\.id) }
    }
    var selectedPR: PullRequest? {
        guard let id = selectedID else { return nil }
        return (all + mergedRows).first { $0.id == id }
    }

    /// Deep link / widget tap: make sure the PR is on screen, then select and expand it.
    func reveal(prID id: String) {
        if let sec = sections.first(where: { $0.prs.contains { $0.id == id } }) {
            prefs.collapsedSections.remove(sec.id)
        }
        statusFilter = []
        selectedID = id
        expandedID = id
    }

    func moveSelection(_ delta: Int) {
        focusedButton = nil
        let ids = visibleRowIDs
        guard !ids.isEmpty else { return }
        guard let cur = selectedID, let i = ids.firstIndex(of: cur) else {
            selectedID = delta >= 0 ? ids.first : ids.last
            return
        }
        selectedID = ids[max(0, min(ids.count - 1, i + delta))]
    }

    /// Returns true when the key was handled. Keys owned by SwiftUI shortcuts (⌘R, ⌘N, ⌘,) fall through.
    func handle(_ key: Hotkey) -> Bool {
        switch key {
        case .moveDown: moveSelection(1)
        case .moveUp: moveSelection(-1)
        case .open:
            if focusedButton != nil, expandedID == selectedID { activateFocused += 1 }
            else if let pr = selectedPR { NSWorkspace.shared.open(pr.url) } else { return false }
        case .expand:
            focusedButton = nil
            if let id = selectedID { toggleExpanded(id) } else { moveSelection(1) }
        case .collapse:
            focusedButton = nil
            if expandedID != nil { expandedID = nil } else { return false }
        case .nextButton, .prevButton:
            guard let id = selectedID, expandedID == id, expandedButtonCount > 0 else { return false }
            let n = expandedButtonCount, step = key == .nextButton ? 1 : -1
            focusedButton = ((focusedButton ?? (step > 0 ? -1 : 0)) + step + n) % n
        case .copyURL: if let pr = selectedPR { PRActions.copyURL(pr) } else { return false }
        case .share: if let pr = selectedPR { PRActions.share(pr) } else { return false }
        case .copyBranch: if let pr = selectedPR { PRActions.copyBranch(pr) } else { return false }
        case .pin: if let pr = selectedPR { togglePin(pr) } else { return false }
        case .fix: if let pr = selectedPR, canFix(pr) { fix(pr, runAgent: true) } else { return false }
        case .hide: if let pr = selectedPR { hide(pr: pr) } else { return false }
        case .checks:
            guard let pr = selectedPR, !pr.checks.isEmpty else { return false }
            NSWorkspace.shared.open(pr.actionsRunURL ?? pr.checksURL)
        case .filterRed: toggleFilter(.failure)
        case .filterYellow: toggleFilter(.pending)
        case .filterGreen: toggleFilter(.success)
        case .clearFilters: statusFilter = []
        case .toggleSections:
            let ids = sections.map(\.id)
            if prefs.collapsedSections.isSuperset(of: ids) { prefs.collapsedSections = [] } else { prefs.collapsedSections = Set(ids) }
        case .showHotkeys: showHotkeys.toggle()
        case .toggleGlobal, .close, .refresh, .watch, .settings: return false
        }
        return true
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
    /// Merged PRs are included only while their merge commit has checks, so a red deploy lights the dots
    /// and a plain "it landed" row never does.
    var all: [PullRequest] {
        var seen = Set<String>()
        var out: [PullRequest] = []
        let mergedWithChecks = merged.filter { !$0.checks.isEmpty }
        for pr in mine + watched + followed.flatMap(\.prs) + mergedWithChecks where seen.insert(pr.id).inserted {
            out.append(pr)
        }
        let hidden = prefs.sources.hiddenPRs
        return Filters.visible(out, ignore: prefs.ignoreRules).filter { hidden[$0.id] == nil }
    }

    /// The Merged section: every merged PR in the window, red first, then newest merge first.
    var mergedRows: [PullRequest] {
        let hidden = prefs.sources.hiddenPRs
        let visible = Filters.visible(merged, ignore: prefs.ignoreRules).filter { hidden[$0.id] == nil }
        return visible.sorted {
            if $0.state != $1.state { return $0.state < $1.state }
            return ($0.mergedAt ?? .distantPast) > ($1.mergedAt ?? .distantPast)
        }
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
        out.append(Section(id: "Mine", title: "My PRs", prs: take(mine)))
        out.append(Section(id: "Watching", title: "Watching", prs: take(watched)))
        for f in followed {
            var title = f.query.title
            if case .author(let login) = f.query, let name = prefs.label(for: login) ?? displayName(for: login) { title = name }
            out.append(Section(id: f.query.title, title: title, prs: take(f.prs), query: f.query))
        }
        // Merged rows aren't in `all` unless they have checks, so filter them directly here.
        let mergedFiltered = mergedRows.filter { pr in
            !claimed.contains(pr.id) && (filter.isEmpty || filter.contains(pr.state))
        }
        out.append(Section(id: "Merged", title: "Merged", prs: mergedFiltered))
        return applyOrder(out).filter { !$0.prs.isEmpty }
    }

    /// All section ids in default order, for drag reordering (includes empty ones so order survives).
    var sectionIDs: [String] {
        applyOrder(["Pinned", "Mine", "Watching"].map { Section(id: $0, title: $0, prs: []) }
                   + followed.map { Section(id: $0.query.title, title: $0.query.title, prs: []) }
                   + [Section(id: "Merged", title: "Merged", prs: [])]).map(\.id)
    }

    private func applyOrder(_ sections: [Section]) -> [Section] {
        let rank = Dictionary(uniqueKeysWithValues: prefs.sectionOrder.enumerated().map { ($1, $0) })
        return sections.enumerated().sorted { a, b in
            switch (rank[a.element.id], rank[b.element.id]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
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
        merged = []
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
            let follow = prefs.followQueries
            let mergedQuery: PRQuery? = prefs.mergedDays > 0 ? .merged(withinDays: prefs.mergedDays) : nil
            let queries = [PRQuery.authored] + follow + (mergedQuery.map { [$0] } ?? [])
            async let searchTask = provider.fetchPullRequests(queries: queries)
            async let watchedTask = provider.fetchPullRequests(refs: refs)
            let (results, freshWatched) = try await (searchTask, watchedTask)
            let previous = all
            mine = results.first ?? []
            followed = Array(zip(follow, results.dropFirst().prefix(follow.count)))
            var freshMerged = mergedQuery == nil ? [] : (results.last ?? [])
            // US-028: a red merge commit that main has since moved past is history, not a problem.
            let redRefs = Set(freshMerged.filter { $0.state == .failure }.map { BranchRef(repo: $0.repo, branch: $0.baseRefName) })
            if !redRefs.isEmpty, let heads = try? await provider.fetchBranchHeadChecks(Array(redRefs)) {
                freshMerged = freshMerged.map { pr in
                    guard pr.state == .failure, let head = heads[BranchRef(repo: pr.repo, branch: pr.baseRefName).key],
                          !head.isEmpty, Rollup.state(for: head) == .success else { return pr }
                    return pr.superseded(note: "\(pr.baseRefName) is green now")
                }
            }
            merged = freshMerged
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
        // The widget mirrors the popover: same sections, same order, merged rows included for display.
        let secs = sections.map { Snapshot.Section(id: $0.id, title: $0.title, prIDs: $0.prs.map(\.id)) }
        var seen = Set<String>()
        let prs = (all + mergedRows).filter { seen.insert($0.id).inserted }
        guard let data = try? SharedStore.encode(prs, pinnedIDs: Array(prefs.pinned), sections: secs) else { return }
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
        let live = Set((mine + watched + followed.flatMap(\.prs) + merged).map(\.id))
        let stale = prefs.pinned.subtracting(live)
        if !stale.isEmpty { prefs.pinned.subtract(stale) }
        let staleAliases = Set(prefs.sources.prAliases.keys).subtracting(live)
        for id in staleAliases { prefs.sources.prAliases[id] = nil }
        // A hidden PR that merged or closed is gone for good; drop it so the Settings list stays honest.
        let staleHidden = Set(prefs.sources.hiddenPRs.keys).subtracting(live)
        for id in staleHidden { prefs.sources.hiddenPRs[id] = nil }
    }

    // MARK: Agent (US-025)

    var agentConfig: AgentLauncher.Config? {
        guard let agent = AgentLauncher.Agent(rawValue: prefs.agent),
              let terminal = AgentLauncher.Terminal(rawValue: prefs.terminal) else { return nil }
        return AgentLauncher.Config(agent: agent, customCommand: prefs.agentCustomCommand, terminal: terminal,
                                    promptTemplate: prefs.promptTemplate, repoPaths: prefs.repoPaths)
    }
    var agentTitle: String { AgentLauncher.Agent(rawValue: prefs.agent)?.title ?? "agent" }
    func canFix(_ pr: PullRequest) -> Bool {
        agentConfig != nil && prefs.repoPaths[pr.repo.lowercased()] != nil && !pr.headRefName.isEmpty
    }
    private(set) var agentError: String?

    /// One button: worktree + terminal + agent with the failure as the prompt.
    func fix(_ pr: PullRequest, runAgent: Bool) {
        guard let config = agentConfig else { agentError = AgentLauncher.Err.noAgent.localizedDescription; return }
        agentError = nil
        Task {
            do { try await AgentLauncher.fix(pr, config: config, runAgent: runAgent) }
            catch { agentError = error.localizedDescription }
        }
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
