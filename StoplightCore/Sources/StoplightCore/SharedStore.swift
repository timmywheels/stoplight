import Foundation
import OSLog

private let log = Logger(subsystem: "com.timwheeler.stoplight", category: "SharedStore")

/// The only bridge between app and widget: one JSON file (US-007). Never contains the token.
/// Already filtered for hidden repos.
public struct Snapshot: Codable, Sendable {
    public let writtenAt: Date
    public let prs: [PullRequest]
    public let pinnedIDs: [String]

    public init(writtenAt: Date = .now, prs: [PullRequest], pinnedIDs: [String] = []) {
        self.writtenAt = writtenAt
        self.prs = prs
        self.pinnedIDs = pinnedIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        writtenAt = try c.decode(Date.self, forKey: .writtenAt)
        prs = try c.decode([PullRequest].self, forKey: .prs)
        pinnedIDs = try c.decodeIfPresent([String].self, forKey: .pinnedIDs) ?? []
    }

    public var isStale: Bool { Date.now.timeIntervalSince(writtenAt) > 5 * 60 }
}

/// Where the snapshot lives.
///
/// App Groups would be the textbook answer, but a `group.*` container needs the group in the
/// provisioning profile, which Personal teams and ad-hoc builds can't get; macOS 15 then denies the
/// sandboxed widget. So the unsandboxed app writes directly into the widget's own sandbox container,
/// which the widget can always read. The App Group path is kept as a secondary location for builds
/// that do have the entitlement.
public enum SharedStore {
    public static let groupID = "group.com.timwheeler.stoplight"
    public static let widgetBundleID = "com.timwheeler.stoplight.widget"
    static let fileName = "prs.json"

    /// App Group container file (works only when the profile grants the group).
    public static var groupFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent(fileName)
    }

    /// The widget's Application Support folder, addressed from OUTSIDE its sandbox (the app side).
    /// Only valid once the widget has run at least once and macOS has created its container.
    public static var widgetContainerFileURL: URL? {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(widgetBundleID)/Data")
        guard FileManager.default.fileExists(atPath: container.path) else { return nil }
        return container.appendingPathComponent("Library/Application Support/Stoplight/\(fileName)")
    }

    /// The same folder, addressed from INSIDE the sandbox (the widget side).
    static var localFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Stoplight/\(fileName)")
    }

    /// App side. Writes to every location we can.
    public static func save(_ prs: [PullRequest], pinnedIDs: [String] = []) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(Snapshot(prs: prs, pinnedIDs: pinnedIDs))
        var wrote = 0
        for url in [widgetContainerFileURL, groupFileURL].compactMap({ $0 }) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                wrote += 1
            } catch {
                log.error("save: \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        if wrote == 0 { log.error("save: no writable location (widget not yet launched?)") }
    }

    /// Widget side. Own container first, App Group second.
    public static func load() -> Snapshot? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        for url in [localFileURL, groupFileURL].compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                let snap = try dec.decode(Snapshot.self, from: data)
                log.notice("load: \(snap.prs.count) PRs from \(url.path, privacy: .public)")
                return snap
            } catch {
                log.error("load: decode failed at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        log.notice("load: no snapshot found")
        return nil
    }

    public static func clear() {
        for url in [widgetContainerFileURL, groupFileURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
