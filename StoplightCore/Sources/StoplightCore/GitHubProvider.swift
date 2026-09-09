import Foundation
import OSLog

private let log = Logger(subsystem: "com.timwheeler.stoplight", category: "GitHub")

public struct GitHubProvider: CIProvider {
    public enum Error: Swift.Error, LocalizedError {
        case http(Int)
        case graphQL(String)
        case unauthorized

        public var errorDescription: String? {
            switch self {
            case .http(let code): "GitHub returned HTTP \(code)"
            case .graphQL(let msg): msg
            case .unauthorized: "GitHub rejected the token"
            }
        }
    }

    public struct RateLimit: Sendable {
        public let remaining: Int
        public let resetAt: Date?
    }

    private let token: String
    private let session: URLSession
    private let endpoint = URL(string: "https://api.github.com/graphql")!

    public init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    /// Most recent rate-limit info seen. Read by the poller to back off (US-002).
    public private(set) nonisolated(unsafe) static var lastRateLimit: RateLimit?

    // MARK: - Public

    public func fetchPullRequests(queries: [PRQuery]) async throws -> [[PullRequest]] {
        guard !queries.isEmpty else { return [] }
        let data = try await post(["query": Self.searchQuery(queries)])
        let env = try Self.decoder.decode(SearchEnvelope.self, from: data)
        guard let results = env.data else {
            throw Error.graphQL(env.errors?.first?.message ?? "Empty response")
        }
        return queries.indices.map { i in
            (results["q\(i)"]??.nodes ?? []).compactMap(Self.map)
        }
    }

    public func fetchPullRequests(refs: [PRRef]) async throws -> [PullRequest] {
        guard !refs.isEmpty else { return [] }
        let data = try await post(["query": Self.refsQuery(refs)])
        let env = try Self.decoder.decode(RefsEnvelope.self, from: data)
        // Partial results are normal here (a private repo you lost access to, a deleted PR). Only throw when nothing came back.
        guard let repos = env.data else {
            throw Error.graphQL(env.errors?.first?.message ?? "Empty response")
        }
        return repos.values.compactMap { $0?.pullRequest }.compactMap(Self.map)
    }

    public func fetchDisplayNames(logins: [String]) async throws -> [String: String] {
        guard !logins.isEmpty else { return [:] }
        let fields = logins.enumerated().map { i, l in "u\(i): user(login: \"\(l)\") { login name }" }
        let data = try await post(["query": "query {\n" + fields.joined(separator: "\n") + "\n}"])
        struct U: Decodable { let login: String; let name: String? }
        struct Env: Decodable { let data: [String: U?]? }
        let users = try JSONDecoder().decode(Env.self, from: data).data ?? [:]
        var out: [String: String] = [:]
        for case let u?? in users.values {
            if let name = u.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { out[u.login.lowercased()] = name }
        }
        return out
    }

    public func fetchBranchStatuses(_ refs: [BranchRef], commits: Int) async throws -> [String: [BranchStatus]] {
        guard !refs.isEmpty else { return [:] }
        // Look past commits that never triggered CI (docs-only, no-op merges) without unbounded history.
        let lookback = min(60, max(10, commits * 5))
        let fields = refs.enumerated().compactMap { i, r -> String? in
            let parts = r.repo.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, Filters.isValidRepo(r.repo), Filters.isValidBranch(r.branch) else { return nil }
            return "b\(i): repository(owner: \"\(parts[0])\", name: \"\(parts[1])\") { ref(qualifiedName: \"refs/heads/\(r.branch)\") { target { ... on Commit { history(first: \(lookback)) { nodes { oid messageHeadline url committedDate ...CommitChecks } } } } } }"
        }
        guard !fields.isEmpty else { return [:] }
        let query = "query {\n" + fields.joined(separator: "\n") + "\n}\n" + Self.commitChecksFragment
        let data = try await post(["query": query])
        struct C: Decodable { let oid: String; let messageHeadline: String; let url: URL; let committedDate: Date; let statusCheckRollup: Node.RollupNode? }
        struct History: Decodable { let nodes: [C] }
        struct Target: Decodable { let history: History? }
        struct Ref: Decodable { let target: Target? }
        struct Repo: Decodable { let ref: Ref? }
        struct Env: Decodable { let data: [String: Repo?]? }
        let repos = try Self.decoder.decode(Env.self, from: data).data ?? [:]
        var out: [String: [BranchStatus]] = [:]
        for (i, r) in refs.enumerated() {
            guard let history = repos["b\(i)"]??.ref?.target?.history?.nodes, let head = history.first else { continue }
            func status(_ c: C) -> BranchStatus {
                BranchStatus(ref: r, sha: c.oid, message: c.messageHeadline, url: c.url,
                             committedAt: c.committedDate, checks: Self.checks(of: c.statusCheckRollup))
            }
            let withChecks = history.filter { !($0.statusCheckRollup?.contexts.nodes.isEmpty ?? true) }
            out[r.key] = withChecks.isEmpty ? [status(head)] : withChecks.prefix(max(1, commits)).map(status)
        }
        return out
    }

    /// The merge queue behind each base branch (US-041). Queues belong to a branch, not to "main":
    /// an org can queue into rc/2026-09, develop, or anything else, so the caller says which.
    /// Entries come back in queue order; each PR keeps its own position from `mergeQueueEntry`.
    public func fetchMergeQueues(_ refs: [BranchRef], limit: Int) async throws -> [String: [PullRequest]] {
        guard !refs.isEmpty else { return [:] }
        let fields = refs.enumerated().compactMap { i, r -> String? in
            let parts = r.repo.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, Filters.isValidRepo(r.repo), Filters.isValidBranch(r.branch) else { return nil }
            return "m\(i): repository(owner: \"\(parts[0])\", name: \"\(parts[1])\") { mergeQueue(branch: \"\(r.branch)\") { entries(first: \(min(max(limit, 1), 50))) { nodes { position state headCommit { ...CommitChecks } pullRequest { ...PRFields } } } } }"
        }
        guard !fields.isEmpty else { return [:] }
        let data = try await post(["query": "query {\n" + fields.joined(separator: "\n") + "\n}\n" + Self.prFields])
        struct Entry: Decodable {
            let position: Int?
            let state: String?
            /// The merge group's commit: what CI is actually running while the PR sits in the queue.
            let headCommit: Node.Commit?
            let pullRequest: Node?
        }
        struct Entries: Decodable { let nodes: [Entry] }
        struct Queue: Decodable { let entries: Entries? }
        struct Repo: Decodable { let mergeQueue: Queue? }
        struct Env: Decodable { let data: [String: Repo?]? }
        let repos = try Self.decoder.decode(Env.self, from: data).data ?? [:]
        var out: [String: [PullRequest]] = [:]
        for (i, r) in refs.enumerated() {
            guard let nodes = repos["m\(i)"]??.mergeQueue?.entries?.nodes else { continue }
            // The entry knows its own position and state; the PR's own mergeQueueEntry can be
            // thinner (a blocked entry reports no position), so the entry wins.
            out[r.key] = nodes.compactMap { entry -> PullRequest? in
                guard let node = entry.pullRequest, let pr = Self.map(node) else { return nil }
                // The PR's own checks passed before it was enqueued; the queue is testing something
                // else. Show the merge group's checks when GitHub has started them.
                let merging = Self.checks(of: entry.headCommit?.statusCheckRollup)
                return pr.asQueueRow(position: entry.position, state: entry.state,
                                     checks: merging.isEmpty ? nil : merging)
            }.sorted { ($0.mergeQueue?.position ?? .max) < ($1.mergeQueue?.position ?? .max) }
        }
        return out
    }

    public func resolveBranchPatterns(_ patterns: [BranchRef]) async throws -> [String: String] {
        var out: [String: String] = [:]
        for p in patterns.filter(\.isPattern) {
            if let name = try await newestMatchingBranch(p) { out[p.key] = name }
        }
        return out
    }

    /// GitHub returns refs alphabetically, 100 per page, and won't order branches by commit date
    /// (`TAG_COMMIT_DATE` is ignored for heads). Taking one page picks the alphabetically-first
    /// branches, which for any dated naming scheme are the oldest. So: page through every ref under
    /// the pattern's literal prefix and choose the newest commit here. No assumptions about naming.
    private func newestMatchingBranch(_ pattern: BranchRef) async throws -> String? {
        let parts = pattern.repo.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, Filters.isValidRepo(pattern.repo) else { return nil }
        struct Target: Decodable { let committedDate: Date? }
        struct Node: Decodable { let name: String; let target: Target? }
        struct Info: Decodable { let hasNextPage: Bool; let endCursor: String? }
        struct Page: Decodable { let pageInfo: Info; let nodes: [Node] }
        struct Repo: Decodable { let refs: Page? }
        struct Payload: Decodable { let repository: Repo? }
        struct Env: Decodable { let data: Payload? }

        var cursor: String?
        var best: (name: String, date: Date)?
        var scanned = 0
        for _ in 0..<10 {   // 1000 refs is plenty; bounded so one huge repo can't stall a poll
            let after = cursor.map { ", after: \"\($0)\"" } ?? ""
            let q = """
            query { repository(owner: "\(parts[0])", name: "\(parts[1])") {
              refs(refPrefix: "refs/heads/", query: "\(pattern.patternPrefix)", first: 100\(after)) {
                pageInfo { hasNextPage endCursor }
                nodes { name target { ... on Commit { committedDate } } }
              } } }
            """
            let data = try await post(["query": q])
            guard let page = try Self.decoder.decode(Env.self, from: data).data?.repository?.refs else { break }
            scanned += page.nodes.count
            for n in page.nodes where pattern.matches(n.name) {
                let d = n.target?.committedDate ?? .distantPast
                if let b = best { if d > b.date { best = (n.name, d) } } else { best = (n.name, d) }
            }
            guard page.pageInfo.hasNextPage, let end = page.pageInfo.endCursor else { break }
            cursor = end
        }
        log.notice("pattern \(pattern.spec, privacy: .public): scanned \(scanned) refs, newest = \(best?.name ?? "none", privacy: .public)")
        return best?.name
    }

    /// Validate the token and return the login (US-001).
    public func viewerLogin() async throws -> String {
        let data = try await post(["query": "{ viewer { login } }"])
        struct V: Decodable { struct D: Decodable { struct Vw: Decodable { let login: String }; let viewer: Vw }; let data: D? }
        guard let login = try JSONDecoder().decode(V.self, from: data).data?.viewer.login else {
            throw Error.graphQL("No viewer in response")
        }
        return login
    }

    // MARK: - Transport

    private func post(_ body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Stoplight/0.1", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        // A stale keep-alive connection surfaces as "network connection was lost" on the first request after idle.
        // One immediate retry clears it.
        var result: (Data, URLResponse)
        do { result = try await session.data(for: req) }
        catch let e as URLError where e.code == .networkConnectionLost || e.code == .cannotConnectToHost {
            result = try await session.data(for: req)
        }
        let (data, resp) = result
        guard let http = resp as? HTTPURLResponse else { throw Error.http(-1) }
        if let rem = http.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap(Int.init) {
            let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset")
                .flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            Self.lastRateLimit = RateLimit(remaining: rem, resetAt: reset)
        }
        if http.statusCode == 401 { throw Error.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw Error.http(http.statusCode) }
        return data
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Queries

    static let prFields = """
    fragment PRFields on PullRequest {
      id
      number
      title
      url
      isDraft
      state
      updatedAt
      headRefOid
      author { login }
      bodyText
      headRefName
      baseRefName
      mergedAt
      mergeQueueEntry { position state }
      mergeStateStatus
      reviewDecision
      repository { nameWithOwner }
      mergeCommit { ...CommitChecks }
      commits(last: 1) { nodes { commit { ...CommitChecks } } }
    }
    \(commitChecksFragment)
    """

    static let commitChecksFragment = """
    fragment CommitChecks on Commit {
      statusCheckRollup {
        state
        contexts(last: 100) {
          nodes {
            __typename
            ... on CheckRun {
              name status conclusion detailsUrl startedAt completedAt
              checkSuite { workflowRun { workflow { name } } }
            }
            ... on StatusContext { context state targetUrl createdAt }
          }
        }
      }
    }
    """

    /// All searches in one request via aliases q0…qN. Query strings only contain validated identifiers.
    static func searchQuery(_ queries: [PRQuery]) -> String {
        let fields = queries.enumerated().map { i, q in
            "q\(i): search(query: \"\(q.githubSearch)\", type: ISSUE, first: 50) { nodes { ... on PullRequest { ...PRFields } } }"
        }
        return "query {\n" + fields.joined(separator: "\n") + "\n}\n" + prFields
    }

    /// One request for all watched refs via aliases. PRRef validates owner/name/number, so interpolation is safe.
    static func refsQuery(_ refs: [PRRef]) -> String {
        let fields = refs.enumerated().map { i, r in
            "r\(i): repository(owner: \"\(r.owner)\", name: \"\(r.name)\") { pullRequest(number: \(r.number)) { ...PRFields } }"
        }
        return "query {\n" + fields.joined(separator: "\n") + "\n}\n" + prFields
    }

    // MARK: - Response shape

    private struct GQLError: Decodable { let message: String }

    private struct SearchEnvelope: Decodable {
        struct Search: Decodable { let nodes: [Node]? }
        let data: [String: Search?]?
        let errors: [GQLError]?
    }

    private struct RefsEnvelope: Decodable {
        struct Repo: Decodable { let pullRequest: Node? }
        let data: [String: Repo?]?
        let errors: [GQLError]?
    }

    private struct Node: Decodable {
        struct Author: Decodable { let login: String }
        struct Repo: Decodable { let nameWithOwner: String }
        struct Commits: Decodable { let nodes: [CommitNode] }
        struct CommitNode: Decodable { let commit: Commit }
        struct Commit: Decodable { let statusCheckRollup: RollupNode? }
        struct RollupNode: Decodable { let state: String?; let contexts: Contexts }
        struct Contexts: Decodable { let nodes: [Context] }
        struct Workflow: Decodable { let name: String? }
        struct WorkflowRun: Decodable { let workflow: Workflow? }
        struct CheckSuite: Decodable { let workflowRun: WorkflowRun? }
        struct Context: Decodable {
            let __typename: String
            // CheckRun
            let name: String?
            let status: String?
            let conclusion: String?
            let detailsUrl: URL?
            let startedAt: Date?
            let completedAt: Date?
            let checkSuite: CheckSuite?
            // StatusContext
            let context: String?
            let state: String?
            let targetUrl: URL?
            let createdAt: Date?
        }

        let id: String?
        let number: Int?
        let title: String?
        let url: URL?
        let isDraft: Bool?
        let state: String?
        let updatedAt: Date?
        let headRefOid: String?
        let author: Author?
        let bodyText: String?
        let headRefName: String?
        let baseRefName: String?
        let mergeQueueEntry: MQ?
        let mergeStateStatus: String?
        let reviewDecision: String?
        let mergedAt: Date?
        let mergeCommit: Commit?
        let repository: Repo?
        struct MQ: Decodable { let position: Int?; let state: String? }
        let commits: Commits?
    }

    private static func map(_ n: Node) -> PullRequest? {
        guard let id = n.id, let number = n.number, let title = n.title, let url = n.url,
              let repo = n.repository?.nameWithOwner, let sha = n.headRefOid else { return nil }
        let status: PRStatus = switch n.state {
        case "MERGED": .merged
        case "CLOSED": .closed
        default: .open
        }
        // Once merged, the branch's checks are history; what matters is what ran on the merge commit (US-022).
        let commit = status == .merged ? n.mergeCommit : n.commits?.nodes.first?.commit

        return PullRequest(
            id: id, repo: repo, number: number, title: title, url: url,
            isDraft: n.isDraft ?? false, updatedAt: n.updatedAt ?? .distantPast,
            headSha: sha, checks: checks(of: commit?.statusCheckRollup),
            author: n.author?.login ?? "ghost", status: status,
            summary: summarize(n.bodyText),
            headRefName: n.headRefName ?? "", baseRefName: n.baseRefName ?? "",
            mergeQueue: n.mergeQueueEntry.map { MergeQueueInfo(position: $0.position ?? 0, state: $0.state ?? "QUEUED") },
            mergeState: MergeState(github: n.mergeStateStatus),
            mergedAt: n.mergedAt,
            review: ReviewDecision(github: n.reviewDecision)
        )
    }

    /// Collapse whitespace, cap at 300 chars.
    static func summarize(_ body: String?) -> String {
        guard let body else { return "" }
        let collapsed = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        return collapsed.count > 300 ? String(collapsed.prefix(300)).trimmingCharacters(in: .whitespaces) + "…" : collapsed
    }

    /// A commit keeps every run that ever reported on it: re-run a workflow and the old, failed
    /// check run is still attached. Keep the newest per workflow and name so a stale failure
    /// doesn't outvote the passing re-run that replaced it.
    private static func checks(of rollup: Node.RollupNode?) -> [CheckResult] {
        Rollup.newestPerCheck((rollup?.contexts.nodes ?? []).compactMap { c in
            guard let check = mapCheck(c) else { return nil }
            let workflow = c.checkSuite?.workflowRun?.workflow?.name ?? ""
            return Rollup.TimedCheck(check: check, workflow: workflow,
                                     at: c.completedAt ?? c.startedAt ?? c.createdAt)
        })
    }

    private static func mapCheck(_ c: Node.Context) -> CheckResult? {
        switch c.__typename {
        case "CheckRun":
            guard let name = c.name else { return nil }
            return CheckResult(name: name, state: checkRunState(status: c.status, conclusion: c.conclusion), url: c.detailsUrl)
        case "StatusContext":
            guard let name = c.context else { return nil }
            return CheckResult(name: name, state: statusContextState(c.state), url: c.targetUrl)
        default:
            return nil
        }
    }

    /// GitHub CheckRun → CheckState. Exposed for tests.
    public static func checkRunState(status: String?, conclusion: String?) -> CheckState {
        if status != "COMPLETED" { return .pending }
        switch conclusion {
        case "SUCCESS": return .success
        case "NEUTRAL", "SKIPPED": return .skipped
        case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE": return .failure
        default: return .pending
        }
    }

    /// GitHub StatusContext → CheckState. Exposed for tests.
    public static func statusContextState(_ state: String?) -> CheckState {
        switch state {
        case "SUCCESS": .success
        case "FAILURE", "ERROR": .failure
        default: .pending  // PENDING, EXPECTED
        }
    }
}
