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
    enum ListKind: String, CaseIterable { case follow, ignore }

    /// Six lists. Stored as one JSON blob so a change to any of them persists together.
    struct Sources: Codable, Equatable {
        var followUsers: [String] = []
        var followRepos: [String] = []
        var followOrgs: [String] = []
        var ignoreUsers: [String] = []
        var ignoreRepos: [String] = []
        var ignoreOrgs: [String] = []

        subscript(kind: SourceKind, list: ListKind) -> [String] {
            get {
                switch (list, kind) {
                case (.follow, .users): followUsers
                case (.follow, .repos): followRepos
                case (.follow, .orgs): followOrgs
                case (.ignore, .users): ignoreUsers
                case (.ignore, .repos): ignoreRepos
                case (.ignore, .orgs): ignoreOrgs
                }
            }
            set {
                switch (list, kind) {
                case (.follow, .users): followUsers = newValue
                case (.follow, .repos): followRepos = newValue
                case (.follow, .orgs): followOrgs = newValue
                case (.ignore, .users): ignoreUsers = newValue
                case (.ignore, .repos): ignoreRepos = newValue
                case (.ignore, .orgs): ignoreOrgs = newValue
                }
            }
        }
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
            src.ignoreRepos = legacy
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
        IgnoreRules(users: Set(sources.ignoreUsers), repos: Set(sources.ignoreRepos), orgs: Set(sources.ignoreOrgs))
    }

    /// Searches to run in addition to `.authored`, in display order.
    var followQueries: [PRQuery] {
        sources.followUsers.map(PRQuery.author) + sources.followRepos.map(PRQuery.repo) + sources.followOrgs.map(PRQuery.org)
    }

    func isFollowing(user: String) -> Bool {
        sources.followUsers.contains { $0.caseInsensitiveCompare(user) == .orderedSame }
    }

    // MARK: Sources editing

    enum AddResult { case added, duplicate, invalid }

    /// Validates, normalizes (strips a leading @), dedupes case-insensitively.
    @discardableResult
    func add(_ raw: String, to kind: SourceKind, list: ListKind) -> AddResult {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("@") { value.removeFirst() }
        let valid = kind == .repos ? Filters.isValidRepo(value) : Filters.isValidLogin(value)
        guard valid else { return .invalid }
        if sources[kind, list].contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) { return .duplicate }
        sources[kind, list].append(value)
        return .added
    }

    func remove(_ value: String, from kind: SourceKind, list: ListKind) {
        sources[kind, list].removeAll { $0.caseInsensitiveCompare(value) == .orderedSame }
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
