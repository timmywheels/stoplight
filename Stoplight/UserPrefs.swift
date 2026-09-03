import Foundation
import Observation
import StoplightCore

/// Hidden repos, watched refs, pins (FR-18).
/// Written to UserDefaults. Optionally mirrored to NSUbiquitousKeyValueStore for iCloud sync across Macs.
/// iCloud is OFF by default: it needs the `com.apple.developer.ubiquity-kvstore-identifier` entitlement,
/// which requires a paid Apple Developer team. To enable: add the entitlement in project.yml and pass
/// `cloud: .default` here.
@MainActor
@Observable
final class UserPrefs {
    private enum Key {
        static let hidden = "hiddenRepos"
        static let watched = "watchedRefs"
        static let pinned = "pinnedIDs"
        static let all = [hidden, watched, pinned]
    }

    var hiddenRepos: Set<String> { didSet { persist(Key.hidden, Array(hiddenRepos).sorted()) } }
    var watched: [PRRef] { didSet { persist(Key.watched, watched.map(\.key)) } }
    var pinned: Set<String> { didSet { persist(Key.pinned, Array(pinned).sorted()) } }

    private let defaults: UserDefaults
    private let cloud: NSUbiquitousKeyValueStore?
    private var applyingRemote = false
    private var observer: (any NSObjectProtocol)?

    init(defaults: UserDefaults = .standard, cloud: NSUbiquitousKeyValueStore? = nil) {
        self.defaults = defaults
        self.cloud = cloud
        cloud?.synchronize()
        // iCloud wins when it has a value; otherwise fall back to the local cache.
        func load(_ key: String) -> [String] {
            cloud?.array(forKey: key) as? [String] ?? defaults.stringArray(forKey: key) ?? []
        }
        hiddenRepos = Set(load(Key.hidden))
        watched = load(Key.watched).compactMap(PRRef.init(key:))
        pinned = Set(load(Key.pinned))

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

    private func persist(_ key: String, _ value: [String]) {
        defaults.set(value, forKey: key)
        guard !applyingRemote, let cloud else { return }
        cloud.set(value, forKey: key)
    }

    /// Another Mac changed something. Take iCloud's value; write-through to defaults only.
    private func applyRemote(keys: [String]) {
        guard let cloud else { return }
        applyingRemote = true
        defer { applyingRemote = false }
        for key in keys {
            let value = cloud.array(forKey: key) as? [String] ?? []
            switch key {
            case Key.hidden: hiddenRepos = Set(value)
            case Key.watched: watched = value.compactMap(PRRef.init(key:))
            case Key.pinned: pinned = Set(value)
            default: break
            }
        }
    }

    func hide(_ repo: String) { hiddenRepos.insert(repo) }
    func unhide(_ repo: String) { hiddenRepos.remove(repo) }

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
}
