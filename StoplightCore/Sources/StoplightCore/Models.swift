import Foundation

/// Rolled-up CI state for one pull request. Exactly four values, per PRD FR-4.
/// Ordering is "worst first" so `min()` over a list yields the aggregate.
public enum CIState: String, Codable, Sendable, CaseIterable, Comparable {
    case failure
    case pending
    case success
    case none

    private var rank: Int {
        switch self {
        case .failure: 0
        case .pending: 1
        case .success: 2
        case .none: 3
        }
    }

    public static func < (lhs: CIState, rhs: CIState) -> Bool { lhs.rank < rhs.rank }
}

/// Provider-neutral state of a single check or status context.
public enum CheckState: String, Codable, Sendable {
    case success
    case failure
    case pending
    /// Skipped or neutral. Counts as success for rollup (US-002).
    case skipped
}

/// Whether the PR itself is still open. Used to auto-drop watched PRs (US-011).
public enum PRStatus: String, Codable, Sendable {
    case open
    case merged
    case closed
}

public struct CheckResult: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let state: CheckState
    public let url: URL?

    public init(name: String, state: CheckState, url: URL?) {
        self.name = name
        self.state = state
        self.url = url
    }
}

/// A pointer to a PR without its data. What the user "watches" (US-011).
public struct PRRef: Codable, Sendable, Hashable, Identifiable {
    public let owner: String
    public let name: String
    public let number: Int

    public var id: String { key }
    /// "owner/repo#123"
    public var key: String { "\(owner)/\(name)#\(number)" }
    public var repo: String { "\(owner)/\(name)" }

    private static let segment = try! NSRegularExpression(pattern: "^[A-Za-z0-9_.-]+$")

    public init?(owner: String, name: String, number: Int) {
        guard number > 0, Self.valid(owner), Self.valid(name) else { return nil }
        self.owner = owner
        self.name = name
        self.number = number
    }

    /// Accepts https://github.com/owner/repo/pull/123 with anything trailing (/files, #issuecomment, ?diff=…).
    public init?(url: URL) {
        guard let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[2] == "pull", let n = Int(parts[3]) else { return nil }
        self.init(owner: parts[0], name: parts[1], number: n)
    }

    /// Parses the `key` form.
    public init?(key: String) {
        guard let hash = key.lastIndex(of: "#"), let n = Int(key[key.index(after: hash)...]) else { return nil }
        let repo = key[..<hash].split(separator: "/", maxSplits: 1).map(String.init)
        guard repo.count == 2 else { return nil }
        self.init(owner: repo[0], name: repo[1], number: n)
    }

    private static func valid(_ s: String) -> Bool {
        segment.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}

/// GitHub merge queue membership (US-016).
public struct MergeQueueInfo: Codable, Sendable, Hashable {
    /// 1-based position in the queue.
    public let position: Int
    /// AWAITING_CHECKS, QUEUED, LOCKED, MERGEABLE, UNMERGEABLE
    public let state: String
    public init(position: Int, state: String) { self.position = position; self.state = state }
    public var isBlocked: Bool { state == "UNMERGEABLE" }
}

public struct PullRequest: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    /// "owner/repo"
    public let repo: String
    public let number: Int
    public let title: String
    public let url: URL
    public let isDraft: Bool
    public let updatedAt: Date
    public let headSha: String
    public let checks: [CheckResult]
    public let author: String
    public let status: PRStatus
    /// First ~300 chars of the PR body, plain text. Shown as a hover tooltip (US-005).
    public let summary: String
    /// Branch names, for stacks (US-015) and "copy branch".
    public let headRefName: String
    public let baseRefName: String
    public let mergeQueue: MergeQueueInfo?
    /// Set for merged PRs (US-022). For those, `checks` are the merge commit's checks on the base branch.
    public let mergedAt: Date?

    public init(id: String, repo: String, number: Int, title: String, url: URL,
                isDraft: Bool, updatedAt: Date, headSha: String, checks: [CheckResult],
                author: String = "", status: PRStatus = .open, summary: String = "",
                headRefName: String = "", baseRefName: String = "", mergeQueue: MergeQueueInfo? = nil,
                mergedAt: Date? = nil) {
        self.id = id
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.isDraft = isDraft
        self.updatedAt = updatedAt
        self.headSha = headSha
        self.checks = checks
        self.author = author
        self.status = status
        self.summary = summary
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.mergeQueue = mergeQueue
        self.mergedAt = mergedAt
    }

    // Tolerant decoding so an older prs.json still loads (author/status added in US-011).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        repo = try c.decode(String.self, forKey: .repo)
        number = try c.decode(Int.self, forKey: .number)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(URL.self, forKey: .url)
        isDraft = try c.decode(Bool.self, forKey: .isDraft)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        headSha = try c.decode(String.self, forKey: .headSha)
        checks = try c.decode([CheckResult].self, forKey: .checks)
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        status = try c.decodeIfPresent(PRStatus.self, forKey: .status) ?? .open
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        headRefName = try c.decodeIfPresent(String.self, forKey: .headRefName) ?? ""
        baseRefName = try c.decodeIfPresent(String.self, forKey: .baseRefName) ?? ""
        mergeQueue = try c.decodeIfPresent(MergeQueueInfo.self, forKey: .mergeQueue)
        mergedAt = try c.decodeIfPresent(Date.self, forKey: .mergedAt)
    }

    public var state: CIState { Rollup.state(for: checks) }
    public var failingChecks: [CheckResult] { checks.filter { $0.state == .failure } }
    public var shortRef: String { "\(repo) #\(number)" }
    /// Base looks like a feature branch rather than a trunk.
    public var hasNonTrunkBase: Bool {
        !baseRefName.isEmpty && !["main", "master", "develop", "dev", "trunk", "release"].contains(baseRefName.lowercased())
    }
    public var ref: PRRef? {
        let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return PRRef(owner: parts[0], name: parts[1], number: number)
    }
}

/// One GitHub search. Mine, or a followed user / repo / org (US-013).
public enum PRQuery: Hashable, Sendable {
    case authored
    case author(String)
    case repo(String)   // "owner/name"
    case org(String)
    /// My PRs merged on or after this day (US-022). Day granularity keeps the query string stable across polls.
    case mergedSince(String)

    public var githubSearch: String {
        let base = "is:pr is:open archived:false"
        switch self {
        case .authored: return "\(base) author:@me"
        case .author(let u): return "\(base) author:\(u)"
        case .repo(let r): return "\(base) repo:\(r)"
        case .org(let o): return "\(base) org:\(o)"
        case .mergedSince(let day): return "is:pr is:merged author:@me merged:>=\(day) sort:updated-desc"
        }
    }

    /// Section header in the popover.
    public var title: String {
        switch self {
        case .authored: "Mine"
        case .author(let u): "@\(u)"
        case .repo(let r): r
        case .org(let o): o
        case .mergedSince: "Merged"
        }
    }

    /// Convenience: merged within the last `days` days.
    public static func merged(withinDays days: Int, now: Date = .now) -> PRQuery {
        let since = Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: now) ?? now
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return .mergedSince(f.string(from: since))
    }
}

public protocol CIProvider: Sendable {
    /// One HTTP request for all queries; results are in the same order as `queries`.
    func fetchPullRequests(queries: [PRQuery]) async throws -> [[PullRequest]]
    /// US-011. Fetches specific PRs by reference. Missing or inaccessible refs are omitted, not thrown.
    func fetchPullRequests(refs: [PRRef]) async throws -> [PullRequest]
    /// US-013. login → profile display name. Logins without a name are omitted.
    func fetchDisplayNames(logins: [String]) async throws -> [String: String]
}

public extension CIProvider {
    func fetchPullRequests(_ query: PRQuery) async throws -> [PullRequest] {
        try await fetchPullRequests(queries: [query]).first ?? []
    }
}

/// What to drop from every surface (US-010). Case-insensitive, exact match.
public struct IgnoreRules: Codable, Sendable, Equatable {
    public var users: Set<String>
    public var repos: Set<String>

    public init(users: Set<String> = [], repos: Set<String> = []) {
        self.users = Set(users.map { $0.lowercased() })
        self.repos = Set(repos.map { $0.lowercased() })
    }

    public static let none = IgnoreRules()
    /// Sensible starting point for the Hide → Users list.
    public static let defaultHiddenUsers = ["dependabot[bot]", "renovate[bot]", "github-actions[bot]"]

    public func allows(_ pr: PullRequest) -> Bool {
        !repos.contains(pr.repo.lowercased()) && !users.contains(pr.author.lowercased())
    }
}

/// Single place where user preferences shape the PR list, so every surface agrees.
public enum Filters {
    public static func visible(_ prs: [PullRequest], ignore: IgnoreRules) -> [PullRequest] {
        prs.filter(ignore.allows)
    }

    /// GitHub identifiers: usernames and org names.
    public static func isValidLogin(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$", options: .regularExpression) != nil
    }

    /// A login, optionally with GitHub's "[bot]" suffix. For the Hide → Users list.
    public static func isValidAuthor(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})(?:\\[bot\\])?$", options: .regularExpression) != nil
    }

    /// "owner/name"
    public static func isValidRepo(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9_.-]{1,100}$", options: .regularExpression) != nil
    }
}
