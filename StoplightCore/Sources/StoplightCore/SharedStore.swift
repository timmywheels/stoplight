import Foundation
import OSLog

private let log = Logger(subsystem: "com.timwheeler.stoplight", category: "SharedStore")

/// The only bridge between app and widget: one JSON file in the App Group (US-007).
/// Never contains the token. Already filtered for hidden repos.
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

public enum SharedStore {
    public static let groupID = "group.com.timwheeler.stoplight"

    public static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("prs.json")
    }

    public static func save(_ prs: [PullRequest], pinnedIDs: [String] = []) throws {
        guard let url = fileURL else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(Snapshot(prs: prs, pinnedIDs: pinnedIDs))
        try data.write(to: url, options: .atomic)
    }

    public static func load() -> Snapshot? {
        guard let url = fileURL else { log.error("load: no group container URL"); return nil }
        guard let data = try? Data(contentsOf: url) else { log.info("load: no file at \(url.path, privacy: .public)"); return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do { return try dec.decode(Snapshot.self, from: data) }
        catch { log.error("load: decode failed: \(String(describing: error), privacy: .public)"); return nil }
    }

    public static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
