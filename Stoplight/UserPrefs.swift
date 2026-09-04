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
        case users, repos, orgs
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var placeholder: String {
            switch self {
            case .users: "username"
            case .repos: "owner/repo"
            case .orgs: "org"
            }
        }
    }
    /// Follow lists plus the one exclusion list. Stored as one JSON blob.
    struct Sources: Codable, Equatable {
        var followUsers: [String] = []
        var followRepos: [String] = []
        var followOrgs: [String] = []
        var hiddenRepos: [String] = []
        var hiddenUsers: [String] = IgnoreRules.defaultHiddenUsers
        /// login (lowercased) → user-chosen label for the section header. Empty means use GitHub's name.
        var userLabels: [String: String] = [:]

        subscript(follow kind: SourceKind) -> [String] {
            get {
                switch kind {
                case .users: followUsers
                case .repos: followRepos
                case .orgs: followOrgs
                }
            }
            set {
                switch kind {
                case .users: followUsers = newValue
                case .repos: followRepos = newValue
                case .orgs: followOrgs = newValue
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
        }
        private enum LegacyKeys: String, CodingKey { case ignoreRepos, hideBots }
    }

    private enum Key {
        static let sources = "sources"
        static let legacyHidden = "hiddenRepos"
        static let watched = "watchedRefs"
        static let pinned = "pinnedIDs"
        static let all = [sources, watched, pinned]
        static let showCount = Prefs.showCount
        static let housing = Prefs.housing
        static let collapsed = "collapsedSections"
    }

    var sources: Sources { didSet { persistJSON(Key.sources, sources) } }
    var watched: [PRRef] { didSet { persist(Key.watched, watched.map(\.key)) } }
    var pinned: Set<String> { didSet { persist(Key.pinned, Array(pinned).sorted()) } }

    // Menu bar look. Local only, not synced.
    var showCount: Bool { didSet { defaults.set(showCount, forKey: Key.showCount) } }
    var housing: Bool { didSet { defaults.set(housing, forKey: Key.housing) } }
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
        showCount = defaults.bool(forKey: Key.showCount)
        housing = defaults.bool(forKey: Key.housing)
        collapsedSections = Set(defaults.stringArray(forKey: Key.collapsed) ?? [])

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

    func toggleCollapsed(_ section: String) {
        if collapsedSections.contains(section) { collapsedSections.remove(section) } else { collapsedSections.insert(section) }
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
