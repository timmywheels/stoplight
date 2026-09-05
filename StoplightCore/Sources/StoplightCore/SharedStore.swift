import Foundation
import OSLog

private let log = Logger(subsystem: "com.timwheeler.stoplight", category: "SharedStore")

/// The only bridge between app and widget: one JSON file (US-007). Never contains the token.
/// Already filtered for hidden repos.
public struct Snapshot: Codable, Sendable {
    /// The popover's grouping, in the user's order, so the widget shows the same thing (US-023).
    public struct Section: Codable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let prIDs: [String]
        public init(id: String, title: String, prIDs: [String]) { self.id = id; self.title = title; self.prIDs = prIDs }
    }

    public let writtenAt: Date
    public let prs: [PullRequest]
    public let pinnedIDs: [String]
    public let sections: [Section]

    public init(writtenAt: Date = .now, prs: [PullRequest], pinnedIDs: [String] = [], sections: [Section] = []) {
        self.writtenAt = writtenAt
        self.prs = prs
        self.pinnedIDs = pinnedIDs
        self.sections = sections
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        writtenAt = try c.decode(Date.self, forKey: .writtenAt)
        prs = try c.decode([PullRequest].self, forKey: .prs)
        pinnedIDs = try c.decodeIfPresent([String].self, forKey: .pinnedIDs) ?? []
        sections = try c.decodeIfPresent([Section].self, forKey: .sections) ?? []
    }

    /// Rows in popover order: section by section. Falls back to worst-first when no sections were written.
    public var orderedRows: [(section: Section, pr: PullRequest)] {
        let byID = Dictionary(uniqueKeysWithValues: prs.map { ($0.id, $0) })
        if sections.isEmpty {
            let s = Section(id: "All", title: "", prIDs: [])
            return Rollup.sorted(prs, pinnedFirst: Set(pinnedIDs)).map { (s, $0) }
        }
        return sections.flatMap { sec in sec.prIDs.compactMap { byID[$0] }.map { (sec, $0) } }
    }

    /// PRs that count toward the dots: everything except merged rows with nothing on the merge commit.
    public var counted: [PullRequest] { prs.filter { !($0.status == .merged && $0.checks.isEmpty) } }

    public var isStale: Bool { Date.now.timeIntervalSince(writtenAt) > 5 * 60 }
}

/// Where the snapshot lives.
///
/// Primary channel: the app serves it on loopback (`SnapshotServer`) and the widget fetches it.
/// Secondary: the App Group container, for builds whose profile actually grants the group.
/// (Writing into the widget's own container works too, but trips macOS's "access data from other
/// apps" prompt, so we don't.)
public enum SharedStore {
    public static let groupID = "group.com.timwheeler.stoplight"
    public static let loopbackPort: UInt16 = 47391
    public static var loopbackURL: URL { URL(string: "http://127.0.0.1:\(loopbackPort)/prs.json")! }
    static let fileName = "prs.json"

    public static var groupFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent(fileName)
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    public static func encode(_ prs: [PullRequest], pinnedIDs: [String] = [], sections: [Snapshot.Section] = []) throws -> Data {
        try encoder.encode(Snapshot(prs: prs, pinnedIDs: pinnedIDs, sections: sections))
    }

    public static func decode(_ data: Data) -> Snapshot? {
        do { return try decoder.decode(Snapshot.self, from: data) }
        catch { log.error("decode failed: \(String(describing: error), privacy: .public)"); return nil }
    }

    /// App side: best-effort write to the App Group file (harmless no-op where the group isn't granted).
    public static func save(_ data: Data) {
        guard let url = groupFileURL else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Widget side, synchronous fallback when the app isn't running.
    public static func loadFromDisk() -> Snapshot? {
        guard let url = groupFileURL, let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    /// Widget side: ask the running app first, fall back to the file.
    public static func load() async -> Snapshot? {
        var req = URLRequest(url: loopbackURL)
        req.timeoutInterval = 2
        if let (data, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200, let snap = decode(data) {
            log.notice("load: \(snap.prs.count) PRs via loopback")
            return snap
        }
        let disk = loadFromDisk()
        log.notice("load: loopback unavailable, disk \(disk == nil ? "miss" : "hit")")
        return disk
    }

    public static func clear() {
        if let url = groupFileURL { try? FileManager.default.removeItem(at: url) }
    }
}
