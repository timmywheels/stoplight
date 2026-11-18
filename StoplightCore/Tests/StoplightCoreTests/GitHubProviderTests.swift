import XCTest
@testable import StoplightCore

final class GitHubProviderTests: XCTestCase {
    func testCheckURLsDoNotPreventLoadingPullRequests() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CheckURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = GitHubProvider(token: "test-token", session: session)

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
}

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
        let nodes: [[String: Any]] = [1, 2].map { number in
            ["id": "pr-\(number)", "number": number, "title": "PR \(number)",
             "url": "https://github.com/acme/api/pull/\(number)", "headRefOid": "abc123",
             "repository": ["nameWithOwner": "acme/api"],
             "commits": ["nodes": [["commit": ["statusCheckRollup": ["contexts": ["nodes": number == 1 ? contexts : []]]]]]]]
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: ["data": ["q0": ["nodes": nodes]]])
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
