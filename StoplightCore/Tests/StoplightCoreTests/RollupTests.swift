import XCTest
@testable import StoplightCore

final class RollupTests: XCTestCase {
    private func check(_ s: CheckState, _ name: String = "ci") -> CheckResult {
        CheckResult(name: name, state: s, url: nil)
    }

    func testNoChecksIsNone() {
        XCTAssertEqual(Rollup.state(for: []), .none)
    }

    func testAnyFailureWins() {
        XCTAssertEqual(Rollup.state(for: [check(.success), check(.pending), check(.failure)]), .failure)
    }

    func testPendingBeatsSuccess() {
        XCTAssertEqual(Rollup.state(for: [check(.success), check(.pending)]), .pending)
    }

    func testAllSuccess() {
        XCTAssertEqual(Rollup.state(for: [check(.success), check(.success)]), .success)
    }

    func testSkippedAndNeutralCountAsSuccess() {
        XCTAssertEqual(Rollup.state(for: [check(.success), check(.skipped)]), .success)
        XCTAssertEqual(Rollup.state(for: [check(.skipped)]), .success)
    }

    func testAggregateIgnoresDrafts() {
        let red = pr(draft: true, checks: [check(.failure)])
        let green = pr(draft: false, checks: [check(.success)])
        XCTAssertEqual(Rollup.aggregate([red, green]), .success)
        XCTAssertEqual(Rollup.aggregate([]), .none)
    }

    func testSortWorstFirstThenRecent() {
        let old = Date(timeIntervalSince1970: 0)
        let new = Date(timeIntervalSince1970: 100)
        let a = pr(id: "a", updated: old, checks: [check(.success)])
        let b = pr(id: "b", updated: new, checks: [check(.failure)])
        let c = pr(id: "c", updated: old, checks: [check(.failure)])
        XCTAssertEqual(Rollup.sorted([a, b, c]).map(\.id), ["b", "c", "a"])
    }

    // MARK: GitHub mapping

    func testCheckRunMapping() {
        XCTAssertEqual(GitHubProvider.checkRunState(status: "IN_PROGRESS", conclusion: nil), .pending)
        XCTAssertEqual(GitHubProvider.checkRunState(status: "QUEUED", conclusion: nil), .pending)
        XCTAssertEqual(GitHubProvider.checkRunState(status: "COMPLETED", conclusion: "SUCCESS"), .success)
        XCTAssertEqual(GitHubProvider.checkRunState(status: "COMPLETED", conclusion: "NEUTRAL"), .skipped)
        XCTAssertEqual(GitHubProvider.checkRunState(status: "COMPLETED", conclusion: "SKIPPED"), .skipped)
        for bad in ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED"] {
            XCTAssertEqual(GitHubProvider.checkRunState(status: "COMPLETED", conclusion: bad), .failure, bad)
        }
    }

    func testStatusContextMapping() {
        XCTAssertEqual(GitHubProvider.statusContextState("SUCCESS"), .success)
        XCTAssertEqual(GitHubProvider.statusContextState("FAILURE"), .failure)
        XCTAssertEqual(GitHubProvider.statusContextState("ERROR"), .failure)
        XCTAssertEqual(GitHubProvider.statusContextState("PENDING"), .pending)
        XCTAssertEqual(GitHubProvider.statusContextState("EXPECTED"), .pending)
    }

    func testActionsRunURLFromJobURL() {
        let ok = CheckResult(name: "lint", state: .success, url: URL(string: "https://github.com/o/r/actions/runs/111/job/1"))
        let bad = CheckResult(name: "e2e", state: .failure, url: URL(string: "https://github.com/o/r/actions/runs/222/job/9?pr=5"))
        XCTAssertEqual(pr(checks: [ok, bad]).actionsRunURL?.absoluteString, "https://github.com/o/r/actions/runs/222")
        XCTAssertEqual(pr(checks: [ok]).actionsRunURL?.absoluteString, "https://github.com/o/r/actions/runs/111")
        XCTAssertNil(pr(checks: [CheckResult(name: "ci", state: .success, url: URL(string: "https://ci.example.com/b/1"))]).actionsRunURL)
    }

    private func pr(id: String = "x", draft: Bool = false, updated: Date = .now, checks: [CheckResult]) -> PullRequest {
        PullRequest(id: id, repo: "o/r", number: 1, title: "t", url: URL(string: "https://github.com/o/r/pull/1")!,
                    isDraft: draft, updatedAt: updated, headSha: "abc", checks: checks)
    }
}
