import XCTest
@testable import StoplightCore

final class PresenceTests: XCTestCase {
    private func pr(_ id: String, _ s: CheckState?, draft: Bool = false, status: PRStatus = .open) -> PullRequest {
        PullRequest(id: id, repo: "o/r", number: 1, title: "t", url: URL(string: "https://github.com/o/r/pull/1")!,
                    isDraft: draft, updatedAt: .now, headSha: "s",
                    checks: s.map { [CheckResult(name: "ci", state: $0, url: nil)] } ?? [], status: status)
    }

    func testLightsReflectEachStateIndependently() {
        let p = StatusPresence([pr("a", .failure), pr("b", .pending), pr("c", .success)])
        XCTAssertEqual(p, StatusPresence(failure: true, pending: true, success: true))
        XCTAssertEqual(StatusPresence([pr("a", .success)]), StatusPresence(failure: false, pending: false, success: true))
    }

    func testCountsWhatTheRowDotsShow() {
        XCTAssertTrue(StatusPresence([pr("a", .failure, draft: true)]).failure)   // a draft's dot is colored too
        XCTAssertTrue(StatusPresence([pr("b", nil)]).isDark)
        XCTAssertTrue(StatusPresence([]).isDark)
        XCTAssertTrue(StatusPresence([pr("m", .failure, status: .merged)]).isDark)                           // merged rows have no dot
    }

    func testMergeStillRunningLightsYellow() {
        let landing = pr("m", .pending, status: .merged)
        XCTAssertTrue(landing.isLanding)
        XCTAssertTrue(landing.isCounted)
        XCTAssertEqual(landing.effectiveState, .pending)
        XCTAssertEqual(landing.withBaseState(.pending).effectiveState, .pending)
        XCTAssertEqual(StatusPresence([landing]), StatusPresence(failure: false, pending: true, success: false))
        // Once it settles green it's just "landed" again: a row, not a dot.
        XCTAssertFalse(pr("m", .success, status: .merged).isLanding)
        XCTAssertTrue(StatusPresence([pr("m", .success, status: .merged)]).isDark)
    }

    func testMyNewestMergeKeepsItsOwnColor() {
        let green = pr("m", .success, status: .merged).withLatestMerge(true)
        XCTAssertTrue(green.isCounted)
        XCTAssertEqual(StatusPresence([green]), StatusPresence(failure: false, pending: false, success: true))
        // Red stays red even while main is running someone else's commit.
        let red = pr("m", .failure, status: .merged).withLatestMerge(true).withBaseState(.pending)
        XCTAssertEqual(red.effectiveState, .failure)
        XCTAssertTrue(StatusPresence([red]).failure)
        // The flag survives a base-state update, and an older red merge stays history.
        XCTAssertTrue(red.isLatestMerge)
        XCTAssertTrue(StatusPresence([pr("o", .failure, status: .merged).withBaseState(.pending)]).isDark)
        // No checks on the merge commit: nothing to show.
        XCTAssertFalse(pr("n", nil, status: .merged).withLatestMerge(true).isCounted)
    }
}
