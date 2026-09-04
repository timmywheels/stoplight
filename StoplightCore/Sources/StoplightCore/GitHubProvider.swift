import Foundation

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

        let (data, resp) = try await session.data(for: req)
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
      repository { nameWithOwner }
      commits(last: 1) {
        nodes {
          commit {
            statusCheckRollup {
              state
              contexts(first: 100) {
                nodes {
                  __typename
                  ... on CheckRun { name status conclusion detailsUrl }
                  ... on StatusContext { context state targetUrl }
                }
              }
            }
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
        struct Context: Decodable {
            let __typename: String
            // CheckRun
            let name: String?
            let status: String?
            let conclusion: String?
            let detailsUrl: URL?
            // StatusContext
            let context: String?
            let state: String?
            let targetUrl: URL?
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
        let repository: Repo?
        let commits: Commits?
    }

    private static func map(_ n: Node) -> PullRequest? {
        guard let id = n.id, let number = n.number, let title = n.title, let url = n.url,
              let repo = n.repository?.nameWithOwner, let sha = n.headRefOid else { return nil }
        let contexts = n.commits?.nodes.first?.commit.statusCheckRollup?.contexts.nodes ?? []
        let status: PRStatus = switch n.state {
        case "MERGED": .merged
        case "CLOSED": .closed
        default: .open
        }
        return PullRequest(
            id: id, repo: repo, number: number, title: title, url: url,
            isDraft: n.isDraft ?? false, updatedAt: n.updatedAt ?? .distantPast,
            headSha: sha, checks: contexts.compactMap(mapCheck),
            author: n.author?.login ?? "ghost", status: status,
            summary: summarize(n.bodyText)
        )
    }

    /// Collapse whitespace, cap at 300 chars.
    static func summarize(_ body: String?) -> String {
        guard let body else { return "" }
        let collapsed = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        return collapsed.count > 300 ? String(collapsed.prefix(300)).trimmingCharacters(in: .whitespaces) + "…" : collapsed
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
