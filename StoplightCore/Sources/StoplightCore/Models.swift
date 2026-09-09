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

/// Whether GitHub would let this PR merge right now (US-039). Separate from CI: a PR can be
/// "green" and still be unmergeable.
public enum MergeState: String, Codable, Sendable {
    case clean, conflicting, behind, blocked, unstable, draft, unknown

    public init(github: String?) {
        switch github {
        case "CLEAN": self = .clean
        case "DIRTY": self = .conflicting
        case "BEHIND": self = .behind
        case "BLOCKED": self = .blocked
        case "UNSTABLE", "HAS_HOOKS": self = .unstable
        case "DRAFT": self = .draft
        default: self = .unknown
        }
    }

    /// Short label for the row, or nil when there's nothing worth saying.
    public var label: String? {
        switch self {
        case .conflicting: "Conflicts"
        case .behind: "Behind"
        case .blocked: "Blocked"
        case .clean, .unstable, .draft, .unknown: nil
        }
    }
    /// Conflicts need you before anything else can happen.
    public var isBlocking: Bool { self == .conflicting }
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
    public let mergeState: MergeState
    /// Set for merged PRs (US-022). For those, `checks` are the merge commit's checks on the base branch.
    public let mergedAt: Date?
    /// Short, user-facing context shown as a tag (branch patterns show the pattern here).
    public let note: String?
    /// For merged PRs: the current CI state of the base branch (US-028). Drives the branch badge.
    public let baseState: CIState?

    public init(id: String, repo: String, number: Int, title: String, url: URL,
                isDraft: Bool, updatedAt: Date, headSha: String, checks: [CheckResult],
                author: String = "", status: PRStatus = .open, summary: String = "",
                headRefName: String = "", baseRefName: String = "", mergeQueue: MergeQueueInfo? = nil,
                mergeState: MergeState = .unknown,
                mergedAt: Date? = nil, note: String? = nil, baseState: CIState? = nil) {
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
        self.mergeState = mergeState
        self.mergedAt = mergedAt
        self.note = note
        self.baseState = baseState
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
        mergeState = try c.decodeIfPresent(MergeState.self, forKey: .mergeState) ?? .unknown
        mergedAt = try c.decodeIfPresent(Date.self, forKey: .mergedAt)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        baseState = try c.decodeIfPresent(CIState.self, forKey: .baseState)
    }

    /// Same PR, annotated with how its base branch is doing right now (US-028).
    public func withBaseState(_ state: CIState) -> PullRequest {
        PullRequest(id: id, repo: repo, number: number, title: title, url: url, isDraft: isDraft, updatedAt: updatedAt,
                    headSha: headSha, checks: checks, author: author, status: status, summary: summary,
                    headRefName: headRefName, baseRefName: baseRefName, mergeQueue: mergeQueue, mergeState: mergeState,
                    mergedAt: mergedAt, note: note, baseState: state)
    }

    /// The same PR as a queue row (US-041). A distinct id keeps selection, expansion, pins and
    /// aliases independent from the copy sitting in My PRs, which is the same PR twice on screen.
    public func asQueueRow() -> PullRequest {
        PullRequest(id: "queue:\(id)", repo: repo, number: number, title: title, url: url, isDraft: isDraft,
                    updatedAt: updatedAt, headSha: headSha, checks: checks, author: author, status: status,
                    summary: summary, headRefName: headRefName, baseRefName: baseRefName, mergeQueue: mergeQueue,
                    mergeState: mergeState, mergedAt: mergedAt, note: note, baseState: baseState)
    }

    /// A merged PR is a live problem only when its own merge commit is red AND the base branch is still red.
    public var isUnresolvedMerge: Bool { status == .merged && state == .failure && baseState == .failure }

    /// What the UI should count and filter on. Open PRs: their checks. Merged PRs: red only while unresolved,
    /// otherwise "landed" (`.none`) so a fixed-since deploy stops showing as a problem anywhere.
    public var effectiveState: CIState {
        // An open PR you can't merge isn't "good to go", whatever CI says.
        if status == .open, mergeState.isBlocking { return .failure }
        guard status == .merged else { return state }
        if baseState == nil { return state }          // no branch info: fall back to the merge commit itself
        return isUnresolvedMerge ? .failure : .none
    }

    public var state: CIState { Rollup.state(for: checks) }
    public var failingChecks: [CheckResult] { checks.filter { $0.state == .failure } }
    public var isBranch: Bool { number == 0 }
    public var shortRef: String { isBranch ? "\(repo) @ \(headRefName)" : "\(repo) #\(number)" }
    /// GitHub's full checks summary for this PR (every job, every workflow).
    public var checksURL: URL { url.appendingPathComponent("checks") }

    /// The merge queue this PR is waiting in, which is per base branch. nil when it isn't queued.
    public var queueURL: URL? {
        guard mergeQueue != nil, !baseRefName.isEmpty else { return nil }
        return URL(string: "https://github.com/\(repo)/queue/\(baseRefName)")
    }

    /// The Actions run summary page (…/actions/runs/<id>) behind this PR's checks: the run holding the
    /// first failing job, else the first job. nil when checks aren't GitHub Actions.
    public var actionsRunURL: URL? {
        for check in failingChecks + checks {
            guard let u = check.url?.absoluteString,
                  let r = u.range(of: "/actions/runs/[0-9]+", options: .regularExpression) else { continue }
            return URL(string: String(u[..<r.upperBound]))
        }
        return nil
    }
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
    /// Open PRs targeting a branch (US-030): the release's inbound queue.
    case base(repo: String, branch: String)

    public var githubSearch: String {
        let base = "is:pr is:open archived:false"
        switch self {
        case .authored: return "\(base) author:@me"
        case .author(let u): return "\(base) author:\(u)"
        case .repo(let r): return "\(base) repo:\(r)"
        case .org(let o): return "\(base) org:\(o)"
        case .mergedSince(let day): return "is:pr is:merged author:@me merged:>=\(day) sort:updated-desc"
        case .base(let r, let b): return "\(base) repo:\(r) base:\(b)"
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
        case .base(_, let b): "→ \(b)"
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
    /// US-028/029/035. Up to `commits` recent commits per branch, newest first, keyed by `BranchRef.key`.
    /// Commits that ran no checks are skipped; if none did, the head is returned so the branch still shows.
    func fetchBranchStatuses(_ refs: [BranchRef], commits: Int) async throws -> [String: [BranchStatus]]
    /// US-030. For each pattern, the matching branch with the newest commit, keyed by the pattern's `key`. Unmatched patterns are omitted.
    func resolveBranchPatterns(_ patterns: [BranchRef]) async throws -> [String: String]
}

public struct BranchRef: Hashable, Sendable {
    public let repo: String   // "owner/name"
    public let branch: String
    public init(repo: String, branch: String) { self.repo = repo; self.branch = branch }
    public var key: String { "\(repo.lowercased())#\(branch)" }

    /// "owner/repo@branch" or a pattern like "owner/repo@rc/*" (US-030).
    public init?(spec: String) {
        let parts = spec.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, Filters.isValidRepo(parts[0]), Filters.isValidBranchPattern(parts[1]) else { return nil }
        self.init(repo: parts[0], branch: parts[1])
    }
    public var spec: String { "\(repo)@\(branch)" }

    /// Contains a `*`: resolves to the newest matching branch each poll.
    public var isPattern: Bool { branch.contains("*") }
    /// Text before the first `*`, used as the server-side prefix filter.
    public var patternPrefix: String { String(branch.prefix(while: { $0 != "*" })) }
    /// Glob match with `*` matching anything (including slashes).
    public func matches(_ name: String) -> Bool {
        guard isPattern else { return name == branch }
        let parts = branch.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var rest = Substring(name)
        for (i, part) in parts.enumerated() {
            if part.isEmpty { continue }
            guard let r = rest.range(of: part) else { return false }
            if i == 0 && r.lowerBound != rest.startIndex { return false }
            rest = rest[r.upperBound...]
        }
        if let last = parts.last, !last.isEmpty, !name.hasSuffix(last) { return false }
        return true
    }
    public func resolved(to name: String) -> BranchRef { BranchRef(repo: repo, branch: name) }
}

/// The latest CI verdict on a branch (US-029): the newest commit that actually ran checks.
public struct BranchStatus: Sendable, Equatable {
    public let ref: BranchRef
    public let sha: String
    public let message: String
    public let url: URL
    public let committedAt: Date
    public let checks: [CheckResult]
    public init(ref: BranchRef, sha: String, message: String, url: URL, committedAt: Date, checks: [CheckResult]) {
        self.ref = ref; self.sha = sha; self.message = message; self.url = url; self.committedAt = committedAt; self.checks = checks
    }
    public var state: CIState { Rollup.state(for: checks) }

    /// Rendered through the same row as PRs. `number == 0` marks a branch row.
    /// The newest commit keeps a stable id per branch so state changes on it still fire notifications;
    /// older commits are addressed by sha (US-035).
    public func asRow(index: Int = 0) -> PullRequest {
        PullRequest(id: index == 0 ? "branch:\(ref.key)" : "branch:\(ref.key)@\(sha)",
                    repo: ref.repo, number: 0, title: message, url: url, isDraft: false,
                    updatedAt: committedAt, headSha: sha, checks: checks, author: "", status: .open,
                    headRefName: ref.branch, baseRefName: "")
    }
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

    public static func isValidBranch(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z0-9._/-]{1,200}$", options: .regularExpression) != nil && !s.contains("..")
    }

    /// A branch name that may also contain `*` wildcards.
    public static func isValidBranchPattern(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z0-9._/*-]{1,200}$", options: .regularExpression) != nil && !s.contains("..")
    }

    /// "owner/name"
    public static func isValidRepo(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9_.-]{1,100}$", options: .regularExpression) != nil
    }
}
