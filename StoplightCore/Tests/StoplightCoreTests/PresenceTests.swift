import XCTest
@testable import StoplightCore

final class PresenceTests: XCTestCase {
    private func pr(_ id: String, _ s: CheckState?, draft: Bool = false) -> PullRequest {
        PullRequest(id: id, repo: "o/r", number: 1, title: "t", url: URL(string: "https://github.com/o/r/pull/1")!,
                    isDraft: draft, updatedAt: .now, headSha: "s",
                    checks: s.map { [CheckResult(name: "ci", state: $0, url: nil)] } ?? [])
    }

    func testLightsReflectEachStateIndependently() {
        let p = StatusPresence([pr("a", .failure), pr("b", .pending), pr("c", .success)])
        XCTAssertEqual(p, StatusPresence(failure: true, pending: true, success: true))
        XCTAssertEqual(StatusPresence([pr("a", .success)]), StatusPresence(failure: false, pending: false, success: true))
    }

    func testDraftsAndNoChecksStayDark() {
        XCTAssertTrue(StatusPresence([pr("a", .failure, draft: true), pr("b", nil)]).isDark)
        XCTAssertTrue(StatusPresence([]).isDark)
    }
}
