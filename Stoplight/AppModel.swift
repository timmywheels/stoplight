import AppKit
import Foundation
import OSLog
import Observation
import StoplightCore

private let log = Logger(subsystem: "com.timwheeler.stoplight", category: "Model")

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    /// Set by the status panel controller so views (Settings) can pop the panel open.
    var openPanel: (() -> Void)?
    private var firstOpenDone = false
    /// Natural height of the list content, reported by the view so the panel can shrink to fit (US-027).
    var contentHeight: CGFloat = 0
    /// Everything that isn't the list (top bar, footer, search/watch fields, dividers), measured by the view.
    var chromeHeight: CGFloat = 0
    /// Pinned: stays open above other windows, ignores click-outside, keeps wherever you dragged it.
    var pinnedPanel = false
    /// Mirrors the panel's visibility so views can reset transient state (open text fields) on close.
    var panelVisible = false

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
    /// Followed branches' latest CI verdict, as rows (US-029).
    private(set) var branches: [PullRequest] = []
    /// pattern key → resolved branch name, from the last poll (US-030). Changes mean a new release branch.
    private var resolvedPatterns: [String: String] = [:]
    /// Open PRs targeting each resolved release branch (US-030).
    private(set) var inbound: [(query: PRQuery, prs: [PullRequest])] = []
    /// One section per merge queue that a visible PR is sitting in (US-041). Deliberately kept out
    /// of `all`: these are other people's PRs, and they must not light your dots or notify you.
    private(set) var queues: [(ref: BranchRef, prs: [PullRequest])] = []
    /// Last search-derived lists, so a PR that drops out of search can be checked by ref (US-038).
    private var lastSearch: (queries: [PRQuery], mine: [PullRequest], followed: [[PullRequest]], inbound: [[PullRequest]])?
    private(set) var lastRefresh: Date?
    private(set) var lastError: String?
    private(set) var auth: AuthState = .unknown
    private(set) var isRefreshing = false
    private(set) var login: String?
    /// Extra diameter for the passing dot during the one-shot pop (US-004).
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
            case .repo, .base: return "#\(pr.number)"
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
        sections.flatMap { sec in isCollapsed(sec.id) ? [] : Stacks.layout(sec.prs).map(\.id) }
    }
    /// Collapse is suspended while a search or a status filter is active, so matches are never hidden.
    func isCollapsed(_ sectionID: String) -> Bool {
        searchText.trimmingCharacters(in: .whitespaces).isEmpty && statusFilter.isEmpty && prefs.collapsedSections.contains(sectionID)
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
        case .copyHash: if let pr = selectedPR { PRActions.copyHash(pr) } else { return false }
        case .pin: if let pr = selectedPR { togglePin(pr) } else { return false }
        case .fix: if let pr = selectedPR, canRunAgent(pr) { fix(pr, runAgent: true) } else { return false }
        case .review: if let pr = selectedPR, canRunAgent(pr), !pr.isBranch { review(pr) } else { return false }
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
        case .search: isSearching = true
        case .watch: isWatching = true
        case .toggleGlobal, .close, .refresh, .settings: return false
        }
        return true
    }

    /// Text filter (US-032), GitHub-style: bare words, author:, repo:, branch:, is:, #n. Session-only.
    var searchText = ""
    var isSearching = false
    /// The "watch a PR by URL" field. Opened by ⌘N or the dots' right-click menu (US-040).
    var isWatching = false
    private var searchQuery: SearchQuery { SearchQuery(searchText) }
    var searchContext: SearchQuery.Context {
        let names = displayNames, labels = prefs.sources.userLabels, aliases = prefs.sources.prAliases
        return SearchQuery.Context(
            names: { login in [names[login.lowercased()], labels[login.lowercased()]].compactMap { $0 } },
            nickname: { aliases[$0] },
            myLogin: login)
    }
    private func matchesSearch(_ pr: PullRequest) -> Bool { searchQuery.matches(pr, searchContext) }
    /// Completion chips for the search field, drawn from what's currently loaded.
    var searchSuggestions: [SearchQuery.Suggestion] {
        SearchQuery.suggestions(for: searchText, prs: all + mergedRows, searchContext)
    }

    /// Popover status filter (US-018). Empty = show everything. Session-only, not persisted.
    var statusFilter: Set<CIState> = []
    func toggleFilter(_ state: CIState) {
        if statusFilter.contains(state) { statusFilter.remove(state) } else { statusFilter.insert(state) }
    }
    /// Counts per state across everything visible, for the filter buttons.
    func count(_ state: CIState) -> Int { all.filter { $0.effectiveState == state }.count }

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
        // Merged PRs alert only while their own merge is red and the base branch is still red.
        let mergedAlerts = merged.filter { $0.isUnresolvedMerge || ($0.baseState == nil && !$0.checks.isEmpty) }
        for pr in mine + watched + followed.flatMap(\.prs) + inbound.flatMap(\.prs) + branches + mergedAlerts where seen.insert(pr.id).inserted {
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
            let a = $0.isUnresolvedMerge ? 0 : 1, b = $1.isUnresolvedMerge ? 0 : 1
            if a != b { return a < b }
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
                guard filter.isEmpty || filter.contains(pr.effectiveState) else { return false }
                guard matchesSearch(pr) else { return false }
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
        for f in inbound { out.append(Section(id: f.query.title, title: f.query.title, prs: take(f.prs), query: f.query)) }
        out.append(Section(id: "Branches", title: "Branches", prs: take(branches)))
        for q in queues {
            // Queue rows are informational, so they bypass `take`: no claiming, no dot filter.
            let rows = q.prs.filter(matchesSearch)
            out.append(Section(id: Self.queueSectionID(q.ref), title: "Queue → \(q.ref.branch)", prs: rows))
        }
        // Merged rows aren't in `all` unless they have checks, so filter them directly here.
        let mergedFiltered = mergedRows.filter { pr in
            !claimed.contains(pr.id) && (filter.isEmpty || filter.contains(pr.effectiveState)) && matchesSearch(pr)
        }
        out.append(Section(id: "Merged", title: "Merged", prs: mergedFiltered))
        return applyOrder(out).filter { !$0.prs.isEmpty }
    }

    /// All section ids in default order, for drag reordering (includes empty ones so order survives).
    var sectionIDs: [String] {
        applyOrder(["Pinned", "Mine", "Watching"].map { Section(id: $0, title: $0, prs: []) }
                   + followed.map { Section(id: $0.query.title, title: $0.query.title, prs: []) }
                   + inbound.map { Section(id: $0.query.title, title: $0.query.title, prs: []) }
                   + queues.map { Section(id: Self.queueSectionID($0.ref), title: $0.ref.branch, prs: []) }
                   + [Section(id: "Branches", title: "Branches", prs: []), Section(id: "Merged", title: "Merged", prs: [])]).map(\.id)
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
        server.statusProvider = { [weak self] in self?.statusReport ?? [:] }
        server.start()
        Task { await detectAgents() }   // so Settings → Agent is right the first time it opens
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

    /// What /status.json returns. No secrets.
    var statusReport: [String: Any] {
        let authText: String = switch auth {
        case .unknown: "unknown"
        case .signedOut: "signedOut"
        case .signedIn(let l, let src): "signedIn(\(l), \(src.rawValue))"
        case .failed(let m): "failed(\(m))"
        }
        let f = ISO8601DateFormatter()
        return [
            "version": updater.currentVersion,
            "auth": authText,
            "ghPath": TokenSource.ghPath() ?? "not found",
            "lastRefresh": lastRefresh.map(f.string) ?? "never",
            "lastError": lastError ?? "",
            "isRefreshing": isRefreshing,
            "counts": ["mine": mine.count, "watched": watched.count, "followed": followed.reduce(0) { $0 + $1.prs.count },
                       "inbound": inbound.reduce(0) { $0 + $1.prs.count }, "branches": branches.count, "merged": merged.count, "all": all.count,
                       "queued": queues.reduce(0) { $0 + $1.prs.count }],
            "queries": ["follow": prefs.followQueries.count, "branches": prefs.sources.followBranches, "mergedDays": prefs.mergedDays,
                        "queues": queues.map(\.ref.spec)],
            "agent": ["configured": prefs.agent, "installed": installedAgents.map(\.rawValue).sorted(), "repos": prefs.repoPaths.count,
                      "fixArgs": agentConfig?.args(for: .fix) ?? "", "reviewArgs": agentConfig?.args(for: .review) ?? "",
                      "needsAttention": agentNeedsAttention,
                      "sessions": agentStatus.map { "\($0.key.suffix(8))=\($0.value.state)" }.sorted()],
            "rateLimitRemaining": GitHubProvider.lastRateLimit?.remaining ?? -1,
        ]
    }

    /// US-003 adaptive polling.
    private var nextInterval: TimeInterval {
        let chosen = TimeInterval(prefs.refreshRate.rawValue)   // 0 = automatic
        if lastError != nil { return chosen == 0 ? 15 : min(chosen, 60) }   // a failed fetch retries soon, never "5 minutes because the list looks empty"
        if let rl = GitHubProvider.lastRateLimit, rl.remaining < 100 { return max(chosen, 300) }
        if all.contains(where: { $0.state == .pending }) { return chosen == 0 ? 20 : min(chosen, 20) }
        if chosen > 0 { return chosen }
        if all.isEmpty { return 300 }
        return 60
    }

    // MARK: Auth (US-001)

    func signIn() async {
        // The app's own PATH is minimal, so ask a login shell where `gh` is before giving up on it.
        if TokenSource.discoveredGHPath == nil { await TokenSource.discoverGH() }
        guard let found = TokenSource.resolve() else {
            log.error("sign-in: no token from gh (\(TokenSource.ghPath() ?? "not found", privacy: .public)) or Keychain")
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
            log.error("sign-in failed: \(String(describing: error), privacy: .public)")
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
        branches = []
        inbound = []
        auth = .signedOut
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

            // US-030: patterns like rc/* resolve to a concrete branch before anything else runs.
            let patterns = prefs.followedBranches.filter(\.isPattern)
            let resolvedNow = patterns.isEmpty ? [:] : ((try? await provider.resolveBranchPatterns(patterns)) ?? [:])
            let concreteBranches: [BranchRef] = prefs.followedBranches.compactMap { b in
                b.isPattern ? resolvedNow[b.key].map(b.resolved(to:)) : b
            }
            let inboundQueries: [PRQuery] = patterns.compactMap { p in resolvedNow[p.key].map { PRQuery.base(repo: p.repo, branch: $0) } }

            let queries = [PRQuery.authored] + follow + inboundQueries + (mergedQuery.map { [$0] } ?? [])
            async let searchTask = provider.fetchPullRequests(queries: queries)
            async let watchedTask = provider.fetchPullRequests(refs: refs)
            let (results, freshWatched) = try await (searchTask, watchedTask)
            let previous = all
            var cursor = 1
            mine = results.first ?? []
            followed = Array(zip(follow, results.dropFirst(cursor).prefix(follow.count))); cursor += follow.count
            inbound = Array(zip(inboundQueries, results.dropFirst(cursor).prefix(inboundQueries.count))); cursor += inboundQueries.count
            await rescueVanished(provider, queries: Array(queries.prefix(1 + follow.count + inboundQueries.count)))
            var freshMerged = mergedQuery == nil ? [] : (results.dropFirst(cursor).first ?? [])

            // One branch request covers both: followed branches (US-029) and the base branches behind merges (US-028).
            let baseRefs = freshMerged.filter { !$0.baseRefName.isEmpty }.map { BranchRef(repo: $0.repo, branch: $0.baseRefName) }
            let wanted = Array(Set(concreteBranches + baseRefs))
            let statuses = wanted.isEmpty ? [:] : ((try? await provider.fetchBranchStatuses(wanted, commits: prefs.branchCommits)) ?? [:])
            branches = prefs.followedBranches.flatMap { b -> [PullRequest] in
                let concrete = b.isPattern ? resolvedNow[b.key].map(b.resolved(to:)) : b
                guard let c = concrete, let list = statuses[c.key] else { return [] }
                return list.enumerated().map { i, st in
                    let row = st.asRow(index: i)
                    // Pattern rows say which pattern found them.
                    guard b.isPattern else { return row }
                    return PullRequest(id: row.id, repo: row.repo, number: 0, title: row.title, url: row.url, isDraft: false,
                                       updatedAt: row.updatedAt, headSha: row.headSha, checks: row.checks, status: .open,
                                       headRefName: row.headRefName, note: b.branch)
                }
            }
            // Badge each merged PR with how its base branch is doing right now.
            freshMerged = freshMerged.map { pr in
                guard let head = statuses[BranchRef(repo: pr.repo, branch: pr.baseRefName).key]?.first, !head.checks.isEmpty else { return pr }
                return pr.withBaseState(head.state)
            }
            merged = freshMerged
            watched = freshWatched
            await refreshQueues(provider)

            // New release branch? Tell the user (only when we knew the previous one).
            for p in patterns {
                guard let now = resolvedNow[p.key] else { continue }
                if let before = resolvedPatterns[p.key], before != now, let row = branches.first(where: { $0.repo == p.repo && $0.headRefName == now }) {
                    await notifier.post(CIEvent(pr: row, kind: .branchMoved, detail: before))
                }
                resolvedPatterns[p.key] = now
            }
            lastRefresh = .now
            lastError = nil
            pruneClosedWatches()
            prunePins()
            publishSnapshot()
            await notify(previous: previous)
            bobIfJustTurnedGreen()
            reconcileAgentSessions()
            // First run: open the panel so the tour (and the list) is seen without hunting for the dots.
            if !prefs.tourSeen && !firstOpenDone { firstOpenDone = true; openPanel?() }
            await resolveDisplayNames(provider)
        } catch {
            // Keep last good data on screen; surface the error as "stale" (US-002).
            log.error("refresh failed: \(String(describing: error), privacy: .public)")
            lastError = error.localizedDescription
            if case GitHubProvider.Error.unauthorized = error {
                auth = .failed("Token rejected")
                self.provider = nil
            }
        }
    }

    // MARK: Merge queues (US-041)

    static func queueSectionID(_ ref: BranchRef) -> String { "Queue \(ref.spec)" }

    /// Which queues to show is derived, not configured: a queue belongs to a base branch, and orgs
    /// queue into rc/*, develop, whatever. Any PR you can already see that is waiting in a queue
    /// names that queue exactly, so there is nothing to type in and nothing to keep in sync.
    private func refreshQueues(_ provider: GitHubProvider) async {
        guard prefs.showQueues else { queues = []; return }
        let refs = Array(Set(all.filter { $0.mergeQueue != nil && !$0.baseRefName.isEmpty }
            .map { BranchRef(repo: $0.repo, branch: $0.baseRefName) }))
        guard !refs.isEmpty else { queues = []; return }
        guard let found = try? await provider.fetchMergeQueues(refs, limit: prefs.queueItems) else { return }
        queues = refs.sorted { $0.spec < $1.spec }.compactMap { ref in
            guard let prs = found[ref.key], !prs.isEmpty else { return nil }
            return (ref, prs.map { $0.asQueueRow() })
        }
    }

    // MARK: Search flakiness (US-038)

    /// GitHub's search index is eventually consistent: a query that returned seven PRs a minute
    /// ago can return one, with no error and plenty of rate limit left. Anything that vanished is
    /// re-checked by ref — an exact lookup, not search — and put back when it's still open.
    private func rescueVanished(_ provider: GitHubProvider, queries: [PRQuery]) async {
        defer { lastSearch = (queries, mine, followed.map(\.prs), inbound.map(\.prs)) }
        // Only comparable when the same questions were asked in the same order.
        guard let last = lastSearch, last.queries == queries else { return }
        let present = Set((mine + followed.flatMap(\.prs) + inbound.flatMap(\.prs)).map(\.id))
        let gone = (last.mine + last.followed.flatMap { $0 } + last.inbound.flatMap { $0 })
            .filter { $0.status == .open && !present.contains($0.id) }
        let refs = Array(Set(gone.compactMap(\.ref)))
        guard !refs.isEmpty, let rechecked = try? await provider.fetchPullRequests(refs: refs) else { return }
        let alive = Dictionary(rechecked.filter { $0.status == .open }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard !alive.isEmpty else { return }
        log.notice("search dropped \(refs.count, privacy: .public) PRs, \(alive.count, privacy: .public) still open: keeping them")
        mine = Self.restore(alive, into: mine, from: last.mine)
        followed = zip(followed, last.followed).map { ($0.query, Self.restore(alive, into: $0.prs, from: $1)) }
        inbound = zip(inbound, last.inbound).map { ($0.query, Self.restore(alive, into: $0.prs, from: $1)) }
    }

    /// Put each still-open PR back where it sat, using the fresh copy from the ref lookup.
    private static func restore(_ alive: [String: PullRequest], into current: [PullRequest],
                                from before: [PullRequest]) -> [PullRequest] {
        var out = current
        var ids = Set(current.map(\.id))
        for (i, old) in before.enumerated() where !ids.contains(old.id) {
            guard let fresh = alive[old.id] else { continue }
            out.insert(fresh, at: min(i, out.count))
            ids.insert(fresh.id)
        }
        return out
    }

    // MARK: Head-bob (US-004)

    /// One pop, ~0.4s, only on the transition into all-passing. Never loops.
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
        guard let data = try? SharedStore.encode(
            prs,
            pinnedIDs: Array(prefs.pinned),
            sections: secs,
            colorProfile: prefs.colorProfile
        ) else { return }
        server.update(data)
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
        let live = Set((mine + watched + followed.flatMap(\.prs) + inbound.flatMap(\.prs) + merged + branches).map(\.id))
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
        func flags(_ id: String) -> String { agent.permissionModes.first { $0.id == id }?.flags ?? "" }
        return AgentLauncher.Config(agent: agent, customCommand: prefs.agentCustomCommand, terminal: terminal,
                                    promptTemplate: prefs.promptTemplate, reviewTemplate: prefs.reviewTemplate,
                                    repoPaths: prefs.repoPaths,
                                    fixFlags: flags(prefs.agentPermissionMode), reviewFlags: flags(prefs.agentReviewPermissionMode),
                                    extraArgs: prefs.agentExtraArgs)
    }
    var agentTitle: String { AgentLauncher.Agent(rawValue: prefs.agent)?.title ?? "agent" }
    /// Observable so the Settings picker relabels when detection finishes.
    private(set) var installedAgents: Set<AgentLauncher.Agent> = []
    func detectAgents() async { installedAgents = await AgentLauncher.detectAgents() }
    /// Enough to offer the button. A missing local clone is reported when it runs, so the reason is visible
    /// instead of the button silently not existing.
    func canRunAgent(_ pr: PullRequest) -> Bool { agentConfig != nil && !pr.headRefName.isEmpty }
    func hasClone(_ pr: PullRequest) -> Bool { prefs.repoPaths[pr.repo.lowercased()] != nil }
    private(set) var agentError: String?

    /// What each launched agent last reported (US-034). Session-only.
    struct AgentStatus: Equatable { let state: String; let at: Date }   // "working" | "attention" | "done"
    private(set) var agentStatus: [String: AgentStatus] = [:]
    func agentReported(_ state: String, prID: String) {
        agentStatus[prID] = AgentStatus(state: state, at: .now)
        if state == "attention" || state == "done", let pr = (all + mergedRows).first(where: { $0.id == prID }) {
            let kind: CIEvent.Kind = state == "attention" ? .agentAttention : .agentDone
            Task { await notifier.post(CIEvent(pr: pr, kind: kind, detail: agentTitle)) }
        }
    }
    func clearAgentStatus(prID: String) { agentStatus[prID] = nil }
    /// Is there a terminal open for this PR right now?
    func hasAgentSession(_ pr: PullRequest) -> Bool { AgentLauncher.session(for: pr.id) != nil }
    /// Jump to the agent's window and stop the badge nagging (US-038).
    func focusAgent(_ pr: PullRequest) {
        guard let s = AgentLauncher.session(for: pr.id) else { clearAgentStatus(prID: pr.id); return }
        if agentStatus[pr.id]?.state != "working" { agentStatus[pr.id] = AgentStatus(state: "working", at: .now) }
        Task { await AgentLauncher.focus(s) }
    }

    /// Badges for windows that are gone shouldn't linger; sessions that outlived a restart should come back.
    func reconcileAgentSessions() {
        let live = AgentLauncher.liveSessionKeys()
        for (id, st) in agentStatus where st.state == "working" && !live.contains(AgentLauncher.sessionKey(id)) {
            agentStatus[id] = nil
        }
        for pr in all + mergedRows where agentStatus[pr.id] == nil && live.contains(AgentLauncher.sessionKey(pr.id)) {
            agentStatus[pr.id] = AgentStatus(state: "working", at: .now)
        }
    }
    /// Any launched agent waiting on the user. Drives the menu bar marker (US-034).
    var agentNeedsAttention: Bool { agentStatus.values.contains { $0.state == "attention" } }
    private var lastLaunch: [String: Date] = [:]

    /// One button: worktree + terminal + agent with the failure as the prompt.
    func fix(_ pr: PullRequest, runAgent: Bool) { launch(pr, runAgent: runAgent, task: .fix) }
    /// Same plumbing, adversarial-review prompt (US-033).
    func review(_ pr: PullRequest) { launch(pr, runAgent: true, task: .review) }

    private func launch(_ pr: PullRequest, runAgent: Bool, task: AgentLauncher.Job) {
        guard let config = agentConfig else { agentError = AgentLauncher.Err.noAgent.localizedDescription; return }
        // One terminal per PR. A second click focuses the window that's already open (AgentLauncher.fix),
        // and this covers the gap while the first launch is still starting up.
        if let last = lastLaunch[pr.id], Date.now.timeIntervalSince(last) < 10 {
            focusAgent(pr)
            return
        }
        lastLaunch[pr.id] = .now
        agentError = nil
        if runAgent { agentStatus[pr.id] = AgentStatus(state: "working", at: .now) }
        Task {
            do { try await AgentLauncher.fix(pr, config: config, runAgent: runAgent, task: task) }
            catch { agentError = error.localizedDescription; agentStatus[pr.id] = nil }
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

    func colorProfileChanged() {
        publishSnapshot()
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
    static let ghPath = "ghPath"
    static let housing = "menuBarHousing"
    static let colorProfile = "colorProfile"
    static let notifications = "notificationMode"  // all | failOnly | off
}
