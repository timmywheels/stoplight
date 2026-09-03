import XCTest
@testable import StoplightCore

final class TransitionsTests: XCTestCase {
    private func pr(_ id: String = "a", sha: String = "s1", state: CheckState?, draft: Bool = false, status: PRStatus = .open) -> PullRequest {
        PullRequest(id: id, repo: "o/r", number: 1, title: "Title", url: URL(string: "https://github.com/o/r/pull/1")!,
                    isDraft: draft, updatedAt: .now, headSha: sha,
                    checks: state.map { [CheckResult(name: "build", state: $0, url: nil)] } ?? [],
                    author: "me", status: status)
    }

    private func kinds(_ prev: [PullRequest], _ cur: [PullRequest], mode: NotificationMode = .all) -> [CIEvent.Kind] {
        Transitions.events(previous: prev, current: cur, mode: mode).map(\.kind)
    }

    func testPendingToFailureFires() {
        XCTAssertEqual(kinds([pr(state: .pending)], [pr(state: .failure)]), [.failed])
    }

    func testSuccessToFailureFires() {
        XCTAssertEqual(kinds([pr(state: .success)], [pr(state: .failure)]), [.failed])
    }

    func testFailureStaysFailureIsSilent() {
        XCTAssertEqual(kinds([pr(state: .failure)], [pr(state: .failure)]), [])
    }

    func testPendingToSuccessFires() {
        XCTAssertEqual(kinds([pr(state: .pending)], [pr(state: .success)]), [.passed])
    }

    func testSuccessToSuccessIsSilent() {
        XCTAssertEqual(kinds([pr(state: .success)], [pr(state: .success)]), [])
    }

    func testFailureToSuccessIsSilentWithoutNewPush() {
        // A rerun that flips red to green on the same sha: spec only fires green from pending.
        XCTAssertEqual(kinds([pr(state: .failure)], [pr(state: .success)]), [])
    }

    func testNewPushResetsToPending() {
        XCTAssertEqual(kinds([pr(sha: "s1", state: .failure)], [pr(sha: "s2", state: .failure)]), [.failed])
        XCTAssertEqual(kinds([pr(sha: "s1", state: .failure)], [pr(sha: "s2", state: .success)]), [.passed])
        XCTAssertEqual(kinds([pr(sha: "s1", state: .success)], [pr(sha: "s2", state: .pending)]), [])
    }

    func testUnknownPRIsSilent() {
        XCTAssertEqual(kinds([], [pr(state: .failure)]), [])
        XCTAssertEqual(kinds([], [pr(state: .success)]), [])
    }

    func testDraftsAndClosedAreSilent() {
        XCTAssertEqual(kinds([pr(state: .pending, draft: true)], [pr(state: .failure, draft: true)]), [])
        XCTAssertEqual(kinds([pr(state: .pending)], [pr(state: .failure, status: .merged)]), [])
    }

    func testPendingAndNoneAreSilent() {
        XCTAssertEqual(kinds([pr(state: .success)], [pr(state: .pending)]), [])
        XCTAssertEqual(kinds([pr(state: .pending)], [pr(state: nil)]), [])
    }

    func testModes() {
        XCTAssertEqual(kinds([pr(state: .pending)], [pr(state: .success)], mode: .failOnly), [])
        XCTAssertEqual(kinds([pr(state: .pending)], [pr(state: .failure)], mode: .failOnly), [.failed])
        XCTAssertEqual(kinds([pr(state: .pending)], [pr(state: .failure)], mode: .off), [])
    }

    func testEventKeyAndBody() {
        let e = Transitions.events(previous: [pr(state: .pending)], current: [pr(state: .failure)], mode: .all)[0]
        XCTAssertEqual(e.key, "a|s1|failed")
        XCTAssertEqual(e.title, "o/r #1")
        XCTAssertEqual(e.body, "Title\nbuild failed")
    }
}
