import Foundation

/// One review or comment on a PR, as much as a notification needs.
public struct Activity: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case approved, changesRequested, reviewed, comment }

    /// Stable across polls: "review:123", "comment:456".
    public let id: String
    public let kind: Kind
    public let author: String
    /// GitHub says the author is an app, not a person.
    public let isBot: Bool
    /// Plain text, trimmed; may be empty (an approval with no words).
    public let body: String
    public let at: Date
    public let url: URL

    public init(id: String, kind: Kind, author: String, isBot: Bool = false, body: String = "", at: Date, url: URL) {
        self.id = id; self.kind = kind; self.author = author; self.isBot = isBot; self.body = body; self.at = at; self.url = url
    }
}

/// What reviews and comments to tell you about.
public struct ActivityRules: Sendable, Equatable {
    public var reviews: Bool
    public var comments: Bool
    /// Skip anything GitHub marks as an app, and logins ending in "[bot]".
    public var ignoreBots: Bool
    /// Logins to never hear from (case-insensitive; "[bot]" optional).
    public var ignoredAuthors: Set<String>
    /// Only PRs by this login (yours). Nil: every PR in the list.
    public var onlyAuthor: String?

    public init(reviews: Bool = true, comments: Bool = true, ignoreBots: Bool = true, ignoredAuthors: [String] = [], onlyAuthor: String? = nil) {
        self.reviews = reviews
        self.comments = comments
        self.ignoreBots = ignoreBots
        self.ignoredAuthors = Set(ignoredAuthors.map(Self.normalize))
        self.onlyAuthor = onlyAuthor
    }

    public static let off = ActivityRules(reviews: false, comments: false)

    /// "Coderabbitai[bot]" → "coderabbitai": GraphQL drops the suffix, REST keeps it.
    static func normalize(_ login: String) -> String {
        let l = login.lowercased().trimmingCharacters(in: .whitespaces)
        return l.hasSuffix("[bot]") ? String(l.dropLast(5)) : l
    }

    /// Whether `a` (not by `me`) is worth a notification.
    public func allows(_ a: Activity, me: String?) -> Bool {
        if let me, Self.normalize(a.author) == Self.normalize(me) { return false } // your own words
        if ignoreBots, a.isBot || a.author.lowercased().hasSuffix("[bot]") { return false }
        if ignoredAuthors.contains(Self.normalize(a.author)) { return false }
        switch a.kind {
        case .comment: return comments
        case .approved, .changesRequested, .reviewed: return reviews
        }
    }
}

public extension Transitions {
    /// New reviews and comments since the last poll, one event per PR (several at once become one:
    /// "3 new comments from ana, bo"). A PR seen for the first time says nothing: no history dump.
    static func activityEvents(previous: [PullRequest], current: [PullRequest], me: String?, rules: ActivityRules) -> [CIEvent] {
        guard rules.reviews || rules.comments else { return [] }
        let prevByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [CIEvent] = []
        for pr in current where pr.status == .open {
            guard let prev = prevByID[pr.id] else { continue }
            if let only = rules.onlyAuthor, ActivityRules.normalize(pr.author) != ActivityRules.normalize(only) { continue }
            let seen = Set(prev.activity.map(\.id))
            // Only newer than what we had: an item can fall out of the "last N" window and come back.
            let since = prev.activity.map(\.at).max() ?? .distantPast
            let new = pr.activity.filter { !seen.contains($0.id) && $0.at >= since && rules.allows($0, me: me) }
            guard !new.isEmpty else { continue }
            out.append(CIEvent(pr: pr, activity: new))
        }
        return out
    }
}
