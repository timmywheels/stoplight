import AppKit
import Foundation
import Observation
import StoplightCore

/// What to follow and what to ignore, plus watched PRs, pins, and menu bar look (FR-18, US-013).
/// UserDefaults-backed. iCloud mirroring is OFF by default: it needs the
/// `com.apple.developer.ubiquity-kvstore-identifier` entitlement (paid Apple Developer team).
/// To enable: add the entitlement in project.yml and pass `cloud: .default` here.
@MainActor
@Observable
final class UserPrefs {
    enum SourceKind: String, CaseIterable, Identifiable {
        case users, repos, orgs, branches
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var placeholder: String {
            switch self {
            case .users: "username"
            case .repos: "owner/repo"
            case .orgs: "org"
            case .branches: "owner/repo@branch"
            }
        }
    }
    /// Follow lists plus the one exclusion list. Stored as one JSON blob.
    struct Sources: Codable, Equatable {
        var followUsers: [String] = []
        var followRepos: [String] = []
        var followOrgs: [String] = []
        /// "owner/repo@branch" (US-029)
        var followBranches: [String] = []
        var hiddenRepos: [String] = []
        var hiddenUsers: [String] = IgnoreRules.defaultHiddenUsers
        /// login (lowercased) → user-chosen label for the section header. Empty means use GitHub's name.
        var userLabels: [String: String] = [:]
        /// PR id → nickname shown instead of the title (US-019). The real title stays in the tooltip.
        var prAliases: [String: String] = [:]
        /// PR id → "owner/repo#123 title", for individually hidden PRs (US-010). Label is for the Settings list.
        var hiddenPRs: [String: String] = [:]

        subscript(follow kind: SourceKind) -> [String] {
            get {
                switch kind {
                case .users: followUsers
                case .repos: followRepos
                case .orgs: followOrgs
                case .branches: followBranches
                }
            }
            set {
                switch kind {
                case .users: followUsers = newValue
                case .repos: followRepos = newValue
                case .orgs: followOrgs = newValue
                case .branches: followBranches = newValue
                }
            }
        }

        // Tolerate the short-lived ignoreRepos key and default hideBots to on.
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            followUsers = try c.decodeIfPresent([String].self, forKey: .followUsers) ?? []
            followRepos = try c.decodeIfPresent([String].self, forKey: .followRepos) ?? []
            followOrgs = try c.decodeIfPresent([String].self, forKey: .followOrgs) ?? []
            followBranches = try c.decodeIfPresent([String].self, forKey: .followBranches) ?? []
            hiddenRepos = try c.decodeIfPresent([String].self, forKey: .hiddenRepos)
                ?? (try? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent([String].self, forKey: .ignoreRepos)) ?? []
            // Older blobs had a hideBots Bool; map it onto the default bot list.
            if let users = try c.decodeIfPresent([String].self, forKey: .hiddenUsers) {
                hiddenUsers = users
            } else {
                let legacyBots = (try? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Bool.self, forKey: .hideBots)) ?? true
                hiddenUsers = legacyBots ? IgnoreRules.defaultHiddenUsers : []
            }
            userLabels = try c.decodeIfPresent([String: String].self, forKey: .userLabels) ?? [:]
            prAliases = try c.decodeIfPresent([String: String].self, forKey: .prAliases) ?? [:]
            hiddenPRs = try c.decodeIfPresent([String: String].self, forKey: .hiddenPRs) ?? [:]
        }
        private enum LegacyKeys: String, CodingKey { case ignoreRepos, hideBots }
    }

    private enum Key {
        static let sources = "sources"
        static let legacyHidden = "hiddenRepos"
        static let watched = "watchedRefs"
        static let pinned = "pinnedIDs"
        static let all = [sources, watched, pinned]
        static let ghPath = Prefs.ghPath
        static let housing = Prefs.housing
        static let colorProfile = Prefs.colorProfile
        static let collapsed = "collapsedSections"
        static let mergedDays = "mergedDays"
        static let branchCommits = "branchCommits"
        static let sectionOrder = "sectionOrder"
        static let tourSeen = "tourSeen"
        static let rowActions = "rowActions"
        static let rowActionsSeen = "rowActionsSeen"
        static let sectionCounts = "sectionCounts"
        static let statusGlyphs = "statusGlyphs"
        static let haptics = "haptics"
        static let density = "density"
        static let appearance = "appearance"
        static let hiddenRowDetails = "hiddenRowDetails"
        static let primaryClick = "primaryClick"
        static let stackOrder = "stackCopyOrder"
        static let showQueues = "showQueues"
        static let queueItems = "queueItems"
        static let rememberedQueues = "rememberedQueues"
        static let pinnedQueues = "pinnedQueues"
        static let refreshSeconds = "refreshSeconds"
        static let notifyReviews = "notifyReviews"
        static let notifyComments = "notifyComments"
        static let notifyActivityOn = "notifyActivityOn"
        static let ignoreBotActivity = "ignoreBotActivity"
        static let mutedAuthors = "mutedAuthors"
    }


    var sources: Sources { didSet { persistJSON(Key.sources, sources) } }
    var watched: [PRRef] { didSet { persist(Key.watched, watched.map(\.key)) } }
    var pinned: Set<String> { didSet { persist(Key.pinned, Array(pinned).sorted()) } }

    /// Where `gh` lives, when it isn't somewhere obvious. Empty means "find it automatically".
    var ghPath: String { didSet { defaults.set(ghPath, forKey: Key.ghPath) } }

    // Appearance. Local only, not synced.
    var housing: Bool { didSet { defaults.set(housing, forKey: Key.housing) } }
    var colorProfile: ColorProfile { didSet { defaults.set(colorProfile.rawValue, forKey: Key.colorProfile) } }
    /// Recently-merged window in days (US-022). 0 = off. Local only.
    var mergedDays: Int { didSet { defaults.set(mergedDays, forKey: Key.mergedDays) } }

    /// Show a section for each merge queue any visible PR is waiting in (US-041). Local only.
    var showQueues: Bool { didSet { defaults.set(showQueues, forKey: Key.showQueues) } }
    /// How many entries of each queue to list.
    var queueItems: Int { didSet { defaults.set(queueItems, forKey: Key.queueItems) } }
    /// Queues a PR of yours has waited in, "owner/repo@branch" → when one last did (seconds since 1970).
    /// Kept so the queue stays on screen when it's empty. Local only.
    var rememberedQueues: [String: Double] { didSet { defaults.set(rememberedQueues, forKey: Key.rememberedQueues) } }
    /// Queues you asked to always show, "owner/repo@branch". They never expire. Local only.
    var pinnedQueues: [String] { didSet { defaults.set(pinnedQueues, forKey: Key.pinnedQueues) } }
    /// How long a remembered queue stays without a PR of yours passing through it.
    static let queueMemory: TimeInterval = 30 * 24 * 3600

    /// Note that a PR of yours is in `spec`'s queue right now. Writes only when the day changes, not every poll.
    func rememberQueues(_ specs: [String], now: Date = .now) {
        var next = rememberedQueues
        for spec in specs where now.timeIntervalSince1970 - (next[spec] ?? 0) > 24 * 3600 { next[spec] = now.timeIntervalSince1970 }
        if next != rememberedQueues { rememberedQueues = next }
    }
    /// Remembered and pinned queues worth asking GitHub about, oldest memories dropped.
    func queueSpecs(now: Date = .now) -> [String] {
        let fresh = rememberedQueues.filter { now.timeIntervalSince1970 - $0.value < Self.queueMemory }.map(\.key)
        return Array(Set(fresh + pinnedQueues))
    }
    func isQueuePinned(_ spec: String) -> Bool { pinnedQueues.contains(spec) }
    func toggleQueuePin(_ spec: String) {
        if let i = pinnedQueues.firstIndex(of: spec) { pinnedQueues.remove(at: i) } else { pinnedQueues.append(spec) }
    }
    /// Stop showing a queue until a PR of yours waits in it again.
    func forgetQueue(_ spec: String) {
        pinnedQueues.removeAll { $0 == spec }
        rememberedQueues[spec] = nil
    }

    /// Which end of a stack "Copy stack as Markdown" starts from.
    enum StackOrder: String, CaseIterable, Identifiable {
        case bottomFirst, topFirst
        var id: String { rawValue }
        var title: String { self == .bottomFirst ? "Bottom of the stack first" : "Top of the stack first" }
    }
    /// Local only.
    var stackOrder: StackOrder { didSet { defaults.set(stackOrder.rawValue, forKey: Key.stackOrder) } }

    /// Idle seconds between refreshes. 0 keeps the adaptive schedule, which is what most people want.
    /// A chosen value still tightens while checks are running and still backs off near the rate limit.
    enum RefreshRate: Int, CaseIterable, Identifiable {
        case automatic = 0, halfMinute = 30, minute = 60, twoMinutes = 120, fiveMinutes = 300, quarterHour = 900
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .automatic: "Automatically"
            case .halfMinute: "Every 30 seconds"
            case .minute: "Every minute"
            case .twoMinutes: "Every 2 minutes"
            case .fiveMinutes: "Every 5 minutes"
            case .quarterHour: "Every 15 minutes"
            }
        }
    }
    /// Local only.
    var refreshRate: RefreshRate { didSet { defaults.set(refreshRate.rawValue, forKey: Key.refreshSeconds) } }

    /// What a single click on a PR row does; the other action moves to double-click (US-037).
    enum PrimaryClick: String, CaseIterable, Identifiable {
        case open, expand
        var id: String { rawValue }
        var title: String { self == .open ? "Opens it on GitHub" : "Shows its details" }
    }
    /// Local only.
    var primaryClick: PrimaryClick { didSet { defaults.set(primaryClick.rawValue, forKey: Key.primaryClick) } }

    enum SectionCounts: String, CaseIterable, Identifiable {
        case attention, full, off
        var id: String { rawValue }
    }
    /// What a collapsed header shows next to its title (US-018). Local only.
    var sectionCounts: SectionCounts { didSet { defaults.set(sectionCounts.rawValue, forKey: Key.sectionCounts) } }

    /// A row says its status as a few glyphs (hover for the words) instead of a row of tags. Local only.
    var statusGlyphs: Bool { didSet { defaults.set(statusGlyphs, forKey: Key.statusGlyphs) } }
    /// Trackpad ticks on drag, copy and pick (see `Haptics`).
    var haptics: Bool { didSet { defaults.set(haptics, forKey: Key.haptics) } }

    /// How much room each row gets. Only spacing and layout: what a row says is `hiddenRowDetails`.
    enum Density: String, CaseIterable, Identifiable {
        case compact, standard, comfortable
        var id: String { rawValue }
        var title: String {
            switch self {
            case .compact: "Compact"
            case .standard: "Default"
            case .comfortable: "Comfortable"
            }
        }
        /// Above and below each row's content.
        var rowPadding: CGFloat {
            switch self {
            case .compact: 5
            case .standard: 8
            case .comfortable: 12
            }
        }
    }
    /// Light or dark for Stoplight's own windows, or whatever macOS is set to.
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
        /// App-wide, so every window redraws all of itself (a per-window appearance left the Settings
        /// toolbar behind). The status item draws in the menu bar's appearance regardless.
        @MainActor func apply() {
            NSApp.appearance = nsAppearance
            for w in NSApp.windows { w.appearance = nil } // drop any per-window override from before
        }
    }
    /// Local only.
    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: Key.appearance); MainActor.assumeIsolated { appearance.apply() } } }

    /// Local only.
    var density: Density { didSet { defaults.set(density.rawValue, forKey: Key.density) } }

    /// The parts of a row besides its dot and title, each one switchable.
    enum RowDetail: String, CaseIterable, Identifiable {
        case ref, author, status, age
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ref: "Repository and number"
            case .author: "Avatars"
            case .status: "Status: conflicts, reviews, queue"
            case .age: "Last updated"
            }
        }
    }
    /// Stored as what's hidden, so a detail added later shows up by default. Local only.
    var hiddenRowDetails: Set<String> { didSet { defaults.set(Array(hiddenRowDetails).sorted(), forKey: Key.hiddenRowDetails) } }
    func showsDetail(_ d: RowDetail) -> Bool { !hiddenRowDetails.contains(d.rawValue) }
    func setDetail(_ d: RowDetail, shown: Bool) {
        if shown { hiddenRowDetails.remove(d.rawValue) } else { hiddenRowDetails.insert(d.rawValue) }
    }

    /// Which circular buttons an expanded row shows, in order (US-031). Local only.
    var rowActions: [RowAction] { didSet { defaults.set(rowActions.map(\.rawValue), forKey: Key.rowActions) } }

    // Review and comment notifications. Local only.
    /// Tell me about new reviews (approved, changes requested, a review with a summary).
    var notifyReviews: Bool { didSet { defaults.set(notifyReviews, forKey: Key.notifyReviews) } }
    /// Tell me about new comments (conversation and inline replies).
    var notifyComments: Bool { didSet { defaults.set(notifyComments, forKey: Key.notifyComments) } }
    enum ActivityScope: String, CaseIterable, Identifiable {
        case mine, everything
        var id: String { rawValue }
        var title: String { self == .mine ? "My pull requests" : "Every pull request in Stoplight" }
    }
    /// Whose PRs: only yours, or everything you follow and watch.
    var notifyActivityOn: ActivityScope { didSet { defaults.set(notifyActivityOn.rawValue, forKey: Key.notifyActivityOn) } }
    /// Skip reviews and comments from bots (GitHub apps, "[bot]" accounts).
    var ignoreBotActivity: Bool { didSet { defaults.set(ignoreBotActivity, forKey: Key.ignoreBotActivity) } }
    /// People and bots whose reviews and comments never notify you.
    var mutedAuthors: [String] { didSet { defaults.set(mutedAuthors, forKey: Key.mutedAuthors) } }

    /// Adds a login to the mute list: trims, strips "@", checks it's a login, dedupes.
    @discardableResult
    func mute(_ raw: String) -> AddResult {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("@") { value.removeFirst() }
        guard Filters.isValidAuthor(value) else { return .invalid }
        if mutedAuthors.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) { return .duplicate }
        mutedAuthors.append(value)
        return .added
    }

    /// What the notification rules are right now, for `login` (you).
    func activityRules(login: String?) -> ActivityRules {
        guard NotificationService.mode != .off else { return .off }
        return ActivityRules(reviews: notifyReviews, comments: notifyComments, ignoreBots: ignoreBotActivity,
                             ignoredAuthors: mutedAuthors, onlyAuthor: notifyActivityOn == .mine ? (login ?? "") : nil)
    }

    /// First-run tour dismissed (US-024). Local only.
    var tourSeen: Bool { didSet { defaults.set(tourSeen, forKey: Key.tourSeen) } }
    /// How many recent commits each followed branch shows (US-035). 1 = just the latest.
    var branchCommits: Int { didSet { defaults.set(branchCommits, forKey: Key.branchCommits) } }
    /// Section ids in the user's drag order (US-023). Ids not listed keep their default relative order after these.
    var sectionOrder: [String] { didSet { defaults.set(sectionOrder, forKey: Key.sectionOrder) } }
    /// Popover section titles the user has collapsed. Local only.
    var collapsedSections: Set<String> { didSet { defaults.set(Array(collapsedSections).sorted(), forKey: Key.collapsed) } }

    private let defaults: UserDefaults
    private let cloud: NSUbiquitousKeyValueStore?
    private var applyingRemote = false
    private var observer: (any NSObjectProtocol)?

    init(defaults: UserDefaults = .standard, cloud: NSUbiquitousKeyValueStore? = nil) {
        self.defaults = defaults
        self.cloud = cloud
        cloud?.synchronize()
        func load(_ key: String) -> [String] {
            cloud?.array(forKey: key) as? [String] ?? defaults.stringArray(forKey: key) ?? []
        }
        func loadJSON<T: Decodable>(_ key: String, _ type: T.Type) -> T? {
            let data = (cloud?.data(forKey: key)) ?? defaults.data(forKey: key)
            return data.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }
        var src = loadJSON(Key.sources, Sources.self) ?? Sources()
        // Migrate the pre-Sources "hiddenRepos" list once.
        if src == Sources(), let legacy = defaults.stringArray(forKey: Key.legacyHidden), !legacy.isEmpty {
            src.hiddenRepos = legacy
            defaults.removeObject(forKey: Key.legacyHidden)
        }
        sources = src
        watched = load(Key.watched).compactMap(PRRef.init(key:))
        pinned = Set(load(Key.pinned))
        ghPath = defaults.string(forKey: Key.ghPath) ?? ""
        housing = defaults.bool(forKey: Key.housing)
        colorProfile = defaults.string(forKey: Key.colorProfile).flatMap(ColorProfile.init(rawValue:)) ?? .standard
        // Merged starts collapsed: a one-line count until you ask for it.
        collapsedSections = Set(defaults.stringArray(forKey: Key.collapsed) ?? ["Merged"])
        mergedDays = defaults.object(forKey: Key.mergedDays) == nil ? 1 : defaults.integer(forKey: Key.mergedDays)
        sectionOrder = defaults.stringArray(forKey: Key.sectionOrder) ?? []
        branchCommits = defaults.object(forKey: Key.branchCommits) == nil ? 1 : max(1, min(10, defaults.integer(forKey: Key.branchCommits)))
        tourSeen = defaults.bool(forKey: Key.tourSeen)
        // Buttons added in a later version join an existing config once, so an upgrade never hides a new
        // action; ones the user actually unchecked stay off because they were already "seen".
        if var saved = defaults.stringArray(forKey: Key.rowActions)?.compactMap(RowAction.init(rawValue:)) {
            let seen = Set(defaults.stringArray(forKey: Key.rowActionsSeen) ?? [])
            saved += RowAction.defaultOrder.filter { !seen.contains($0.rawValue) && !saved.contains($0) }
            rowActions = saved
            defaults.set(saved.map(\.rawValue), forKey: Key.rowActions)
        } else {
            rowActions = RowAction.defaultOrder
        }
        defaults.set(RowAction.allCases.map(\.rawValue), forKey: Key.rowActionsSeen)
        sectionCounts = SectionCounts(rawValue: defaults.string(forKey: Key.sectionCounts) ?? "") ?? .off
        statusGlyphs = defaults.object(forKey: Key.statusGlyphs) as? Bool ?? true
        haptics = defaults.object(forKey: Key.haptics) as? Bool ?? true
        density = Density(rawValue: defaults.string(forKey: Key.density) ?? "") ?? .standard
        appearance = Appearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        hiddenRowDetails = Set(defaults.stringArray(forKey: Key.hiddenRowDetails) ?? [])
        primaryClick = PrimaryClick(rawValue: defaults.string(forKey: Key.primaryClick) ?? "") ?? .open
        refreshRate = RefreshRate(rawValue: defaults.integer(forKey: Key.refreshSeconds)) ?? .automatic
        stackOrder = StackOrder(rawValue: defaults.string(forKey: Key.stackOrder) ?? "") ?? .bottomFirst
        showQueues = defaults.object(forKey: Key.showQueues) as? Bool ?? true
        queueItems = max(1, defaults.object(forKey: Key.queueItems) as? Int ?? 10)
        rememberedQueues = defaults.dictionary(forKey: Key.rememberedQueues) as? [String: Double] ?? [:]
        pinnedQueues = defaults.stringArray(forKey: Key.pinnedQueues) ?? []
        // The agent launcher is gone (0.15); drop what it saved.
        defaults.removeObject(forKey: "showCountInMenuBar")   // the menu bar number is gone too
        for k in ["agent", "agentCustomCommand", "agentPermissionMode", "agentReviewPermissionMode", "agentExtraArgs", "terminal",
                  "agentPrompt", "agentReviewPrompt", "repoScanRoot", "repoScanRoots", "repoPaths"] { defaults.removeObject(forKey: k) }
        notifyReviews = defaults.object(forKey: Key.notifyReviews) as? Bool ?? true
        notifyComments = defaults.object(forKey: Key.notifyComments) as? Bool ?? true
        notifyActivityOn = ActivityScope(rawValue: defaults.string(forKey: Key.notifyActivityOn) ?? "") ?? .mine
        ignoreBotActivity = defaults.object(forKey: Key.ignoreBotActivity) as? Bool ?? true
        mutedAuthors = defaults.stringArray(forKey: Key.mutedAuthors) ?? []

        if let cloud {
            observer = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: cloud, queue: .main
            ) { [weak self] note in
                let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? Key.all
                MainActor.assumeIsolated { self?.applyRemote(keys: changed) }
            }
        }
    }

    // MARK: Derived

    var ignoreRules: IgnoreRules {
        IgnoreRules(users: Set(sources.hiddenUsers), repos: Set(sources.hiddenRepos))
    }

    var followedBranches: [BranchRef] { sources.followBranches.compactMap(BranchRef.init(spec:)) }

    /// Searches to run in addition to `.authored`, in display order.
    var followQueries: [PRQuery] {
        sources.followUsers.map(PRQuery.author) + sources.followRepos.map(PRQuery.repo) + sources.followOrgs.map(PRQuery.org)
    }

    func isFollowing(user: String) -> Bool {
        sources.followUsers.contains { $0.caseInsensitiveCompare(user) == .orderedSame }
    }

    // MARK: Sources editing

    /// Normalizes a typed value (trims, strips a leading @) and validates it for the given list.
    static func normalize(_ raw: String, kind: SourceKind, hideList: Bool) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("@") { value.removeFirst() }
        let valid: Bool = switch kind {
        case .repos: Filters.isValidRepo(value)
        case .users: hideList ? Filters.isValidAuthor(value) : Filters.isValidLogin(value)
        case .orgs: Filters.isValidLogin(value)
        case .branches: BranchRef(spec: value) != nil
        }
        return valid ? value : nil
    }

    enum AddResult { case added, duplicate, invalid }

    /// Validates, normalizes (strips a leading @), dedupes case-insensitively.
    @discardableResult
    func follow(_ raw: String, kind: SourceKind) -> AddResult {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("@") { value.removeFirst() }
        let valid = kind == .repos ? Filters.isValidRepo(value) : Filters.isValidLogin(value)
        guard valid else { return .invalid }
        if sources[follow: kind].contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) { return .duplicate }
        sources[follow: kind].append(value)
        return .added
    }

    func unfollow(_ value: String, kind: SourceKind) {
        sources[follow: kind].removeAll { $0.caseInsensitiveCompare(value) == .orderedSame }
        if kind == .users { sources.userLabels[value.lowercased()] = nil }
    }

    func label(for login: String) -> String? {
        let l = sources.userLabels[login.lowercased()]?.trimmingCharacters(in: .whitespaces)
        return (l?.isEmpty ?? true) ? nil : l
    }

    func setLabel(_ label: String, for login: String) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        sources.userLabels[login.lowercased()] = trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    func hide(repo raw: String) -> AddResult {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Filters.isValidRepo(value) else { return .invalid }
        if sources.hiddenRepos.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) { return .duplicate }
        sources.hiddenRepos.append(value)
        return .added
    }

    func unhide(repo value: String) {
        sources.hiddenRepos.removeAll { $0.caseInsensitiveCompare(value) == .orderedSame }
    }

    /// Drag `moving` onto `target`. Dropping on a header below it lands after that header; above it, before.
    func moveSection(_ moving: String, onto target: String, currentOrder: [String]) {
        guard moving != target else { return }
        var order = currentOrder
        guard let from = order.firstIndex(of: moving), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        // After the removal, `to` points just past the target when moving down (lands after it),
        // and at the target when moving up (lands before it). Exactly the list-reorder feel.
        order.insert(moving, at: min(to, order.count))
        sectionOrder = order
    }

    func toggleCollapsed(_ section: String) {
        if collapsedSections.contains(section) { collapsedSections.remove(section) } else { collapsedSections.insert(section) }
    }

    func hide(pr: PullRequest) { sources.hiddenPRs[pr.id] = "\(pr.shortRef) \(pr.title)" }
    func unhide(prID: String) { sources.hiddenPRs[prID] = nil }
    func isHidden(prID: String) -> Bool { sources.hiddenPRs[prID] != nil }

    func alias(for prID: String) -> String? {
        let a = sources.prAliases[prID]?.trimmingCharacters(in: .whitespaces)
        return (a?.isEmpty ?? true) ? nil : a
    }

    func setAlias(_ alias: String, for prID: String) {
        let trimmed = alias.trimmingCharacters(in: .whitespaces)
        sources.prAliases[prID] = trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Pins / watches

    func togglePin(_ id: String) {
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
    }

    /// Returns false if already watched.
    @discardableResult
    func watch(_ ref: PRRef) -> Bool {
        guard !watched.contains(ref) else { return false }
        watched.append(ref)
        return true
    }

    func unwatch(_ ref: PRRef) { watched.removeAll { $0 == ref } }

    // MARK: Persistence

    private func persist(_ key: String, _ value: [String]) {
        defaults.set(value, forKey: key)
        guard !applyingRemote, let cloud else { return }
        cloud.set(value, forKey: key)
    }

    private func persistJSON<T: Encodable>(_ key: String, _ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
        guard !applyingRemote, let cloud else { return }
        cloud.set(data, forKey: key)
    }

    /// Another Mac changed something. Take iCloud's value; write-through to defaults only.
    private func applyRemote(keys: [String]) {
        guard let cloud else { return }
        applyingRemote = true
        defer { applyingRemote = false }
        for key in keys {
            switch key {
            case Key.sources:
                if let d = cloud.data(forKey: key), let s = try? JSONDecoder().decode(Sources.self, from: d) { sources = s }
            case Key.watched: watched = (cloud.array(forKey: key) as? [String] ?? []).compactMap(PRRef.init(key:))
            case Key.pinned: pinned = Set(cloud.array(forKey: key) as? [String] ?? [])
            default: break
            }
        }
    }
}
