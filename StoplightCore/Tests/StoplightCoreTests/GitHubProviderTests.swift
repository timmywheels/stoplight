import XCTest
@testable import StoplightCore

final class GitHubProviderTests: XCTestCase {
    private func provider(_ proto: URLProtocol.Type) -> (GitHubProvider, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [proto]
        let session = URLSession(configuration: configuration)
        return (GitHubProvider(token: "test-token", session: session), session)
    }

    func testCheckURLsDoNotPreventLoadingPullRequests() async throws {
        let (provider, session) = provider(CheckURLProtocol.self)
        defer { session.invalidateAndCancel() }

        let results = try await provider.fetchPullRequests(queries: [.authored])
        let prs = try XCTUnwrap(results.first)
        XCTAssertEqual(prs.map(\.number), [1, 2])
        let checks = try XCTUnwrap(prs.first).checks
        XCTAssertEqual(checks.count, 12)
        for prefix in ["status", "check"] {
            for suffix in ["empty", "malformed", "relative", "null", "missing"] {
                let check = try XCTUnwrap(checks.first { $0.name == "\(prefix)-\(suffix)" })
                XCTAssertNil(check.url, check.name)
                XCTAssertEqual(check.state, .failure, check.name)
            }
            let valid = try XCTUnwrap(checks.first { $0.name == "\(prefix)-valid" })
            XCTAssertEqual(valid.url?.absoluteString, "https://example.com/check/123")
            XCTAssertEqual(valid.state, .success)
        }
    }

    /// Searches return IDs; detail is fetched once per PR in batches of `detailBatch`, and each
    /// search keeps its own order, including PRs that several searches found.
    func testSearchFetchesEachPRDetailOnceInBatches() async throws {
        let (provider, session) = provider(BatchURLProtocol.self)
        defer { session.invalidateAndCancel() }
        BatchURLProtocol.reset()

        let results = try await provider.fetchPullRequests(queries: [.authored, .author("bob")])
        XCTAssertEqual(results.map { $0.map(\.number) }, [Array(1...25), [30, 3, 31]])
        let batches = BatchURLProtocol.detailBatches()
        XCTAssertEqual(batches.map(\.count).sorted(by: >), [10, 10, 7])   // 27 unique PRs
        XCTAssertEqual(Set(batches.joined()).count, 27)
    }

    func testRateLimitedResponseSaysWhenToRetry() async throws {
        let now = Date(timeIntervalSince1970: 1000)
        func resp(_ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://api.github.com/graphql")!, statusCode: 403, httpVersion: nil, headerFields: headers)!
        }
        XCTAssertEqual(GitHubProvider.retryTime(resp(["Retry-After": "120"]), now: now), now + 120)
        XCTAssertEqual(GitHubProvider.retryTime(resp(["x-ratelimit-remaining": "0", "x-ratelimit-reset": "5000"]), now: now),
                       Date(timeIntervalSince1970: 5000))
        XCTAssertNil(GitHubProvider.retryTime(resp(["x-ratelimit-remaining": "40", "x-ratelimit-reset": "5000"]), now: now))

        let (provider, session) = provider(ForbiddenURLProtocol.self)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await provider.fetchPullRequests(queries: [.authored])
            XCTFail("expected rateLimited")
        } catch GitHubProvider.Error.rateLimited(let until) {
            XCTAssertNotNil(until)
        }
    }

    func testBatchesKeepOrderAndCapConcurrency() async throws {
        let counter = InFlight()
        let out = try await GitHubProvider.inBatches(Array(0..<23), size: 5, maxInFlight: 2) { batch in
            await counter.enter()
            try await Task.sleep(for: .milliseconds(10))
            await counter.leave()
            return batch
        }
        XCTAssertEqual(out.map(\.count), [5, 5, 5, 5, 3])
        XCTAssertEqual(Array(out.joined()), Array(0..<23))
        let peak = await counter.peak
        XCTAssertEqual(peak, 2)
    }
}

private actor InFlight {
    var now = 0, peak = 0
    func enter() { now += 1; peak = max(peak, now) }
    func leave() { now -= 1 }
}

/// The request's GraphQL body (URLProtocol sees a stream, not `httpBody`).
private func body(_ request: URLRequest) -> [String: Any] {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

private func prNode(_ number: Int, contexts: [[String: Any]] = []) -> [String: Any] {
    ["id": "pr-\(number)", "number": number, "title": "PR \(number)",
     "url": "https://github.com/acme/api/pull/\(number)", "headRefOid": "abc123",
     "repository": ["nameWithOwner": "acme/api"],
     "commits": ["nodes": [["commit": ["statusCheckRollup": ["contexts": ["nodes": contexts]]]]]]]
}

private extension URLProtocol {
    func respond(_ json: Any, status: Int = 200, headers: [String: String]? = nil) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Answers the ID search with pr-1, pr-2, then each detail batch with those PRs.
private final class CheckURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let values: [(String, Any?)] = [
            ("empty", ""), ("malformed", "http://["), ("relative", "checks/123"),
            ("null", NSNull()), ("missing", nil), ("valid", "https://example.com/check/123")
        ]
        let contexts = ["status", "check"].flatMap { prefix in
            values.map { suffix, value in
                var context: [String: Any] = prefix == "status"
                    ? ["__typename": "StatusContext", "context": "\(prefix)-\(suffix)",
                       "state": suffix == "valid" ? "SUCCESS" : "FAILURE"]
                    : ["__typename": "CheckRun", "name": "\(prefix)-\(suffix)", "status": "COMPLETED",
                       "conclusion": suffix == "valid" ? "SUCCESS" : "FAILURE"]
                context[prefix == "status" ? "targetUrl" : "detailsUrl"] = value
                return context
            }
        }
        let b = body(request)
        if let ids = (b["variables"] as? [String: Any])?["ids"] as? [String] {
            respond(["data": ["nodes": ids.map { id -> [String: Any] in
                let n = Int(id.dropFirst(3))!
                return prNode(n, contexts: n == 1 ? contexts : [])
            }]])
        } else {
            respond(["data": ["q0": ["nodes": [["id": "pr-1"], ["id": "pr-2"]]]]])
        }
    }

    override func stopLoading() {}
}

/// q0 finds PRs 1…25; q1 finds 30, 3 (also in q0) and 31. Records each detail batch.
private final class BatchURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var batches: [[String]] = []
    private static let lock = NSLock()
    static func reset() { lock.withLock { batches = [] } }
    static func detailBatches() -> [[String]] { lock.withLock { batches } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let b = body(request)
        if let ids = (b["variables"] as? [String: Any])?["ids"] as? [String] {
            Self.lock.withLock { Self.batches.append(ids) }
            respond(["data": ["nodes": ids.map { prNode(Int($0.dropFirst(3))!) }]])
        } else {
            let ids = { (ns: [Int]) in ns.map { ["id": "pr-\($0)"] } }
            respond(["data": ["q0": ["nodes": ids(Array(1...25))], "q1": ["nodes": ids([30, 3, 31])]]])
        }
    }

    override func stopLoading() {}
}

private final class ForbiddenURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        respond(["message": "You have exceeded a secondary rate limit"], status: 403, headers: ["Retry-After": "60"])
    }
    override func stopLoading() {}
}
