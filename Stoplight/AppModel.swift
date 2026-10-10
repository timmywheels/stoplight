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
        /// Where the section itself lives on GitHub. Queue sections link to their queue.
        var url: URL? = nil
        /// Set on a merge queue's section.
        var queue: BranchRef? = nil

        /// Rows drop whatever the header already says (US-005: no duplicated data).
        var hidesAuthor: Bool { if case .author = query { return true }; return false }
        func refLabel(for pr: PullRequest) -> String {
            if queue != nil { return "#\(pr.number)" } // one queue is one repo, and the header names it
            switch query {
            case .repo, .base: return "#\(pr.number)"
            default:
                // Say only what tells the rows apart: the section's main repo → "#801" (the header
                // names it once), any other → "stoplight #3". The owner is on hover.
                if pr.isBranch { return pr.shortRef }
                if let main = mainRepo, pr.repo.lowercased() == main.lowercased() { return "#\(pr.number)" }
                return "\(pr.repo.split(separator: "/").last.map(String.init) ?? pr.repo) #\(pr.number)"
            }
        }

        /// The repo at least half the rows are in, when there's more than one row.
        var mainRepo: String? {
            let repos = prs.filter { !$0.isBranch }.map(\.repo)
            guard repos.count > 1 else { return nil }
            let counts = Dictionary(repos.map { ($0.lowercased(), 1) }, uniquingKeysWith: +)
            guard let top = counts.max(by: { $0.value < $1.value }), top.value * 2 >= repos.count else { return nil }
            return repos.first { $0.lowercased() == top.key }
        }
        /// What the header adds after the title when the rows dropped it: "servicepro".
        var headerNote: String? {
            if queue != nil { return nil } // the header names the queue's repo itself
            switch query {
            case .repo, .base: return nil // the title already names it
            default: return mainRepo.flatMap { $0.split(separator: "/").last.map(String.init) }
            }
        }
    }

    /// The one expanded row (US-021). Accordion: expanding another collapses this one. Session-only.
    var expandedID: String?
    func toggleExpanded(_ id: String) { expandedID = expandedID == id ? nil : id }

    // MARK: Keyboard (US-026)

    /// Keyboard selection. Session-only. Nil until the user touches the arrow keys.
    var selectedID: String?
    /// The multi-selection (⌘- or ⇧-click): your own open PRs, to close together. Session-only.
    var picked: Set<String> = []
    /// Only your own open PRs can be picked: they're the only ones you can close.
    func canPick(_ pr: PullRequest) -> Bool {
        isMine(pr) && pr.status == .open && !pr.isBranch && !pr.id.hasPrefix("queue:")
    }
    func togglePicked(_ pr: PullRequest) {
        guard canPick(pr) else { NSSound.beep(); return }
        if picked.contains(pr.id) { picked.remove(pr.id) } else { picked.insert(pr.id) }
        Haptics.tick()
    }
    /// What closing `pr` from its right-click menu would close: the whole pick when it's part of one.
    func closeTargets(for pr: PullRequest) -> [PullRequest] {
        guard canPick(pr) else { return [] }
        return picked.contains(pr.id) ? all.filter { picked.contains($0.id) && canPick($0) } : [pr]
    }

    /// Ask, then close `prs` on GitHub (yours, open), refresh, and say what GitHub refused.
    func confirmAndClose(_ prs: [PullRequest]) {
        let prs = prs.filter(canPick)
        guard !prs.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = prs.count == 1 ? "Close \(prs[0].shortRef)?" : "Close \(prs.count) pull requests?"
        alert.informativeText = (prs.count == 1 ? prs[0].title + "\n\n" : "") + "They close on GitHub without merging. You can reopen them there."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let failed = await close(prs)
            guard !failed.isEmpty else { return }
            let err = NSAlert()
            err.messageText = failed.count == 1 ? "One didn't close" : "\(failed.count) didn't close"
            err.informativeText = failed.joined(separator: "\n")
            err.runModal()
        }
    }

    /// Close `prs` on GitHub, then refresh. Returns what failed, as "repo#n: reason".
    func close(_ prs: [PullRequest]) async -> [String] {
        guard let provider else { return ["Not signed in to GitHub"] }
        var failed: [String] = []
        for pr in prs {
            do { try await provider.closePullRequest(repo: pr.repo, number: pr.number) }
            catch { failed.append("\(pr.shortRef): \(error.localizedDescription)") }
        }
        picked.subtract(prs.map(\.id))
        await refresh()
        return failed
    }
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
        case .toggleTab:
            guard hasQueues else { return false }
            tab = tab == .prs ? .queue : .prs
        case .toggleGlobal, .close, .refresh, .settings: return false
        }
        return true
    }

    /// Text filter (US-032), GitHub-style: bare words, author:, repo:, branch:, is:, sha:, #n. Session-only.
    var searchText = "" { didSet { if searchText != oldValue { searchTextChanged() } } }
    var isSearching = false
    /// The "watch a PR by URL" field. Opened by ⌘N or the dots' right-click menu (US-040).
    var isWatching = false
    private var searchQuery: SearchQuery { SearchQuery(searchText) }
    /// The PR a pasted link names, when the search is one.
    var searchedPullRequest: PRRef? { searchQuery.pullRequest }
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
        let local = SearchQuery.suggestions(for: searchText, prs: all + mergedRows, searchContext)
        // People GitHub found for author:<partial>, after the ones already on your PRs.
        guard let partial = authorPartial, partial == peopleQuery else { return local }
        let known = Set(local.map { $0.insert.lowercased() })
        return local + people.filter { !known.contains("author:" + $0.login.lowercased()) }.map { p in
            SearchQuery.Suggestion(label: p.name.map { "\(p.login) · \($0)" } ?? p.login, insert: "author:" + p.login)
        }
    }

    /// author:<2+ letters> being typed: what to ask GitHub for.
    private var authorPartial: String? {
        guard let last = searchText.split(separator: " ", omittingEmptySubsequences: false).last?.lowercased(),
              last.hasPrefix("author:") else { return nil }
        let p = String(last.dropFirst(7)).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        return p.count >= 2 ? p : nil
    }
    /// GitHub's answer for `peopleQuery`, and whether one is on its way (the chip row shows a spinner).
    private(set) var people: [(login: String, name: String?)] = []
    private(set) var peopleQuery: String?
    private(set) var peopleLoading = false
    @ObservationIgnored private var peopleTask: Task<Void, Never>?

    /// A typed PR number none of your rows has: that number in the repo it most likely means.
    /// A `repo:` term picks the repo; otherwise it's the one most of your PRs are in.
    var searchedNumber: PRRef? {
        let q = searchQuery
        guard q.pullRequest == nil, q.typedNumbers.count == 1, let n = Int(q.typedNumbers[0]),
              q.words.isEmpty, q.shas.isEmpty else { return nil }
        let rows = all + mergedRows
        let repos = rows.map(\.repo).filter { r in q.repos.allSatisfy { r.lowercased().contains($0) } }
        let counts = Dictionary(repos.map { ($0, 1) }, uniquingKeysWith: +)
        guard let repo = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        return PRRef(key: "\(repo)#\(n)")
    }

    // MARK: Commit hash search

    /// The hash being searched for, when the search is one.
    var searchedCommit: String? { searchQuery.shas.first }
    /// PRs GitHub says contain `commitQuery`, for when none of the loaded rows has it as its head.
    private(set) var commitMatches: [PullRequest] = []
    private(set) var commitQuery: String?
    private(set) var commitLoading = false
    @ObservationIgnored private var commitTask: Task<Void, Never>?

    /// What a hash search found on GitHub, with the loaded copy of any PR that's already in a list.
    var commitResults: [PullRequest] {
        guard let sha = searchedCommit, sha == commitQuery else { return [] }
        let loaded = Dictionary((all + mergedRows).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return commitMatches.map { loaded[$0.id] ?? $0 }
    }

    /// Every owner Stoplight already looks at: yours, the ones you follow, and the loaded rows'.
    private var knownOwners: [String] {
        let s = prefs.sources
        var owners = Set((all + mergedRows).compactMap { $0.repo.split(separator: "/").first.map(String.init) })
        owners.formUnion(s.followOrgs + s.followUsers + s.followRepos.compactMap { $0.split(separator: "/").first.map(String.init) })
        if let login { owners.insert(login) }
        return owners.sorted()
    }

    /// A hash: select the row whose head it is, right away. None loaded → ask GitHub (after 300ms; the latest wins).
    private func commitSearchChanged() {
        guard let sha = searchedCommit else {
            commitTask?.cancel(); commitLoading = false; commitMatches = []; commitQuery = nil
            return
        }
        let local = (all + mergedRows).filter(matchesSearch)
        if local.count == 1 { selectedID = local[0].id }
        guard local.isEmpty, let provider, sha != commitQuery else { return }
        commitTask?.cancel()
        commitLoading = true
        let owners = knownOwners
        commitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let found = (try? await provider.pullRequests(containingCommit: sha, owners: owners)) ?? []
            guard !Task.isCancelled, let self else { return }
            self.commitMatches = found
            self.commitQuery = sha
            self.commitLoading = false
            if let first = found.first { self.selectedID = first.id }
        }
    }

    /// Look people up on GitHub as you type author:… (after a 250ms pause; the latest wins).
    private func searchTextChanged() {
        commitSearchChanged()
        guard let partial = authorPartial, let provider else { peopleTask?.cancel(); peopleLoading = false; return }
        guard partial != peopleQuery else { return }
        peopleTask?.cancel()
        peopleLoading = true
        peopleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = (try? await provider.searchUsers(partial)) ?? []
            guard !Task.isCancelled, let self else { return }
            self.people = found
            self.peopleQuery = partial
            self.peopleLoading = false
        }
    }

    /// Popover status filter (US-018). Empty = show everything. Session-only, not persisted.
    var statusFilter: Set<CIState> = []
    func toggleFilter(_ state: CIState) {
        if statusFilter.contains(state) { statusFilter.remove(state) } else { statusFilter.insert(state) }
    }
    /// Counts per state across everything visible, for the filter buttons.
    /// Open PRs with that color dot: what the footer and the menu bar dots both show.
    func count(_ state: CIState) -> Int { all.filter { $0.isCounted && $0.effectiveState == state }.count }

    /// login (lowercased) → display name, for followed users (US-013).
    private(set) var displayNames: [String: String] = [:]
    private var namesFetchedFor: Set<String> = []

    func displayName(for login: String) -> String? { displayNames[login.lowercased()] }

    /// Everything visible, deduped, ignore rules applied. Source of truth for dots, widget, notifications.
    /// Merged PRs are included only while their merge commit is running or red, so a running or red
    /// deploy lights the dots and a plain "it landed" row never does.
    var all: [PullRequest] {
        var seen = Set<String>()
        var out: [PullRequest] = []
        // Merged PRs show up while their merge commit is running, or while it and the base branch are red.
        let mergedAlerts = merged.filter { $0.isTrackedMerge || $0.isUnresolvedMerge || ($0.baseState == nil && !$0.checks.isEmpty) }
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
                guard filter.isEmpty || (pr.isCounted && filter.contains(pr.effectiveState)) else { return false }
                guard matchesSearch(pr) else { return false }
                let isPinned = prefs.pinned.contains(pr.id)
                return pinnedOnly ? isPinned : (!skipPinned || !isPinned)
            }
            picked.forEach { claimed.insert($0.id) }
            return Rollup.sorted(picked)
        }
        var out: [Section] = []
        out.append(Section(id: "Pinned", title: "Pinned", prs: take(all, pinnedOnly: true)))
        // Merges whose CI the dots show sit with your PRs (tagged Merged).
        out.append(Section(id: "Mine", title: "My PRs", prs: take(mine + merged.filter(\.isTrackedMerge))))
        out.append(Section(id: "Watching", title: "Watching", prs: take(watched)))
        for f in followed {
            var title = f.query.title
            if case .author(let login) = f.query, let name = prefs.label(for: login) ?? displayName(for: login) { title = name }
            out.append(Section(id: f.query.title, title: title, prs: take(f.prs), query: f.query))
        }
        for f in inbound { out.append(Section(id: f.query.title, title: f.query.title, prs: take(f.prs), query: f.query)) }
        out.append(Section(id: "Branches", title: "Branches", prs: take(branches)))
        // Merged rows have no dot, so a color filter hides them along with the other uncounted rows.
        let mergedFiltered = filter.isEmpty ? mergedRows.filter { !claimed.contains($0.id) && matchesSearch($0) } : []
        out.append(Section(id: "Merged", title: "Merged", prs: mergedFiltered))
        return applyOrder(out).filter { !$0.prs.isEmpty }
    }

    /// All section ids in default order, for drag reordering (includes empty ones so order survives).
    var sectionIDs: [String] {
        applyOrder(["Pinned", "Mine", "Watching"].map { Section(id: $0, title: $0, prs: []) }
                   + followed.map { Section(id: $0.query.title, title: $0.query.title, prs: []) }
                   + inbound.map { Section(id: $0.query.title, title: $0.query.title, prs: []) }
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
    func isWatched(_ pr: PullRequest) -> Bool { pr.ref.map { prefs.watched.contains($0) } ?? false }
    func isMine(_ pr: PullRequest) -> Bool { login.map { $0.caseInsensitiveCompare(pr.author) == .orderedSame } ?? false }
    func isPinned(_ pr: PullRequest) -> Bool { prefs.pinned.contains(pr.id) }
    func displayTitle(_ pr: PullRequest) -> String { prefs.alias(for: pr.id) ?? pr.title }

    // MARK: Lifecycle

    func start() {
        guard loop == nil else { return }
        server.statusProvider = { [weak self] in self?.statusReport ?? [:] }
        server.start()
        loop = Task { [weak self] in
            await self?.signIn()
            while !Task.isCancelled {
                guard let self else { return }
                if self.fullRefreshDue { await self.refresh() } else { await self.refreshPending() }
                await self.updater.checkIfDue()
                try? await Task.sleep(for: .seconds(self.nextInterval))
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
            "rateLimitRemaining": GitHubProvider.lastRateLimit?.remaining ?? -1,
        ]
    }

    /// US-003 polling, easy on GitHub's hourly budget (it's shared with gh and every other tool):
    /// everything every 5 minutes (or your chosen rate), and again when you open the panel on
    /// data over 30 s old; while CI runs, only those PRs, once a minute. A full refresh costs
    /// ~10-15 points; checking a few running PRs ~1-2.
    private var fullInterval: TimeInterval {
        let chosen = TimeInterval(prefs.refreshRate.rawValue)   // 0 = automatic
        if let rl = GitHubProvider.lastRateLimit, rl.remaining < 1000 { return max(chosen, 900) } // running low: back off
        if lastError != nil { return 60 }   // a failed fetch retries soon, never "5 minutes because the list looks empty"
        return chosen > 0 ? chosen : 300
    }

    private var fullRefreshDue: Bool {
        guard let last = lastRefresh else { return true }
        return Date.now.timeIntervalSince(last) >= fullInterval - 1
    }

    private var nextInterval: TimeInterval {
        let untilFull = max(5, fullInterval - Date.now.timeIntervalSince(lastRefresh ?? .distantPast))
        let ciRunning = all.contains { $0.state == .pending && $0.ref != nil }
        return ciRunning ? min(60, untilFull) : untilFull
    }

    /// The panel opened: show fresh data if what's there is over 30 s old.
    func refreshIfStale() {
        // Opening the panel after a failed sign-in: try again now rather than wait for the timer.
        if case .failed = auth {
            signInRetryTask?.cancel()
            Task { await signIn(); if case .signedIn = auth { await refresh() } }
            return
        }
        guard Date.now.timeIntervalSince(lastRefresh ?? .distantPast) > 30 else { return }
        Task { await refresh() }
    }

    /// Between full refreshes: re-fetch only PRs whose CI is still running (one small request),
    /// so a check going green or red still shows up within a minute.
    func refreshPending() async {
        guard let provider, !isRefreshing else { return }
        let refs = all.filter { $0.state == .pending }.compactMap(\.ref)
        guard !refs.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fresh = try await provider.fetchPullRequests(refs: Array(Set(refs)))
            let byID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            func swap(_ list: [PullRequest]) -> [PullRequest] { list.map { byID[$0.id] ?? $0 } }
            let previous = all
            mine = swap(mine)
            watched = swap(watched)
            // The single-PR fetch knows nothing about the base branch or which merge is newest: keep those.
            merged = merged.map { old in
                byID[old.id].map { $0.withBaseState(old.baseState).withLatestMerge(old.isLatestMerge) } ?? old
            }
            followed = followed.map { ($0.query, swap($0.prs)) }
            inbound = inbound.map { ($0.query, swap($0.prs)) }
            publishSnapshot()
            await notify(previous: previous)
            bobIfJustTurnedGreen()
        } catch {
            log.error("pending refresh failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Auth (US-001)

    func signIn() async {
        // The app's own PATH is minimal, so ask a login shell where `gh` is before giving up on it.
        // Only when the usual places come up empty: a slow or stuck shell config must not hold up sign-in.
        if TokenSource.ghPath() == nil { await TokenSource.discoverGH() }
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
            signInRetries = 0
        } catch {
            log.error("sign-in failed: \(String(describing: error), privacy: .public)")
            provider = nil
            auth = .failed(error.localizedDescription)
            // Wi-Fi waking up, a VPN reconnecting: not your token's fault. Try again on our own.
            if error is URLError { scheduleSignInRetry() }
        }
    }

    @ObservationIgnored private var signInRetries = 0
    @ObservationIgnored private var signInRetryTask: Task<Void, Never>?
    private func scheduleSignInRetry() {
        let delays: [Double] = [5, 15, 30, 60]
        let wait = delays[min(signInRetries, delays.count - 1)]
        signInRetries += 1
        signInRetryTask?.cancel()
        signInRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, case .failed = self.auth else { return }
            await self.signIn()
            if case .signedIn = self.auth { await self.refresh() }
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
            // My newest merge into each branch that ran CI: what the dots show once it settles.
            // Merge commits with no checks (a newer push cancelled their run) are skipped.
            var newest: [String: PullRequest] = [:]
            for pr in freshMerged where !pr.checks.isEmpty {
                let key = BranchRef(repo: pr.repo, branch: pr.baseRefName).key
                if (pr.mergedAt ?? .distantPast) > (newest[key]?.mergedAt ?? .distantPast) { newest[key] = pr }
            }
            let latestIDs = Set(newest.values.map(\.id))
            freshMerged = freshMerged.map { $0.withLatestMerge(latestIDs.contains($0.id)) }
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

    /// The Queue tab's sections. Kept out of `sections` so watching a queue doesn't bury your own
    /// PRs under thirty of someone else's. Rows stay in queue order, which is the whole point.
    var queueSections: [Section] {
        let searching = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        return queues.map { q in
            Section(id: Self.queueSectionID(q.ref), title: q.ref.branch.uppercased(),
                    prs: q.prs.filter(matchesSearch),
                    url: URL(string: "https://github.com/\(q.ref.repo)/queue/\(q.ref.branch)"),
                    queue: q.ref)
        }
        // An empty queue stays on screen ("Empty"); while searching, only queues with a match.
        .filter { !searching || !$0.prs.isEmpty }
    }

    /// The queue tab shows once one of your repos has a merge queue, and stays while it's empty.
    var hasQueues: Bool { prefs.showQueues && !queues.isEmpty }

    /// Which half of the panel is showing. Session-only: the panel always opens on your PRs.
    enum Tab: Hashable { case prs, queue }
    var tab: Tab = .prs

    /// Which queues to show: any a visible PR is waiting in right now (a queue belongs to a base
    /// branch, so the PR names it exactly), plus ones a PR of yours used in the last 30 days, plus
    /// ones you pinned. The last two keep a queue on screen while it's empty.
    private func refreshQueues(_ provider: GitHubProvider) async {
        guard prefs.showQueues else { queues = []; return }
        let live = Set(all.filter { $0.mergeQueue != nil && !$0.baseRefName.isEmpty }
            .map { BranchRef(repo: $0.repo, branch: $0.baseRefName) })
        // Where your PRs land (open or just merged): if that branch has a queue, it's yours to watch,
        // whoever is in it right now. Stacked PRs target other PRs' branches, which never have one.
        let prBranches = Set(all.map { BranchRef(repo: $0.repo, branch: $0.headRefName) })
        let landing = Set((mine + merged).filter { !$0.baseRefName.isEmpty }
            .map { BranchRef(repo: $0.repo, branch: $0.baseRefName) })
            .subtracting(prBranches)
        let known = Set(prefs.queueSpecs().compactMap(BranchRef.init(spec:)))
        let refs = Array(live.union(known).union(landing.prefix(20)))
        guard !refs.isEmpty else { queues = []; return }
        guard let found = try? await provider.fetchMergeQueues(refs, limit: prefs.queueItems) else { return }
        // No entry at all means GitHub has no queue on that branch (or the repo is gone): skip it.
        queues = refs.sorted { $0.spec < $1.spec }.compactMap { ref in
            found[ref.key].map { (ref, $0) }
        }
        // Remember every queue you're tied to, so it stays when your PRs move on.
        // Pinned ones aren't copied in: unpinning has to make them go.
        prefs.rememberQueues(queues.map(\.ref).filter { landing.contains($0) }.map(\.spec)
            + all.filter { $0.mergeQueue != nil && isMine($0) }.map { BranchRef(repo: $0.repo, branch: $0.baseRefName).spec })
    }

    func toggleQueuePin(_ ref: BranchRef) { prefs.toggleQueuePin(ref.spec) }
    func forgetQueue(_ ref: BranchRef) {
        prefs.forgetQueue(ref.spec)
        queues.removeAll { $0.ref == ref }
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
        let activity = Transitions.activityEvents(previous: previous, current: current, me: login, rules: prefs.activityRules(login: login))
        // A new approval or change request already says what the decision change would: don't say it twice.
        let reviewed = Set(activity.filter { $0.activity.contains { [.approved, .changesRequested].contains($0.kind) } }.map(\.pr.id))
        // A merge that just went green has left `all`; it still gets its "deployed" notification.
        var seen = Set(current.map(\.id))
        let withMerged = current + mergedRows.filter { seen.insert($0.id).inserted }
        let events = (Transitions.events(previous: previous, current: withMerged, mode: NotificationService.mode)
            .filter { !([.approved, .changesRequested].contains($0.kind) && reviewed.contains($0.pr.id)) } + activity)
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
    static let ghPath = "ghPath"
    static let housing = "menuBarHousing"
    static let colorProfile = "colorProfile"
    static let notifications = "notificationMode"  // all | failOnly | off
}
