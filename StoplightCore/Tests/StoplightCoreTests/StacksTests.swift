import XCTest
@testable import StoplightCore

final class StacksTests: XCTestCase {
    private func pr(_ id: String, head: String, base: String, repo: String = "o/r", state: CheckState = .success, updated: Date = .now) -> PullRequest {
        PullRequest(id: id, repo: repo, number: Int(id.filter(\.isNumber)) ?? 1, title: "T \(id)",
                    url: URL(string: "https://github.com/\(repo)/pull/1")!, isDraft: false, updatedAt: updated, headSha: "s",
                    checks: [CheckResult(name: "ci", state: state, url: nil)], headRefName: head, baseRefName: base)
    }

    func testThreeLevelStackBottomUp() {
        let a = pr("a1", head: "feat-1", base: "main")
        let b = pr("b2", head: "feat-2", base: "feat-1")
        let c = pr("c3", head: "feat-3", base: "feat-2")
        let rows = Stacks.layout([c, a, b])
        XCTAssertEqual(rows.map(\.id), ["a1", "b2", "c3"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2])
        XCTAssertEqual(Set(rows.map(\.stackID)), ["a1"])
    }

    func testStandaloneIsNotStacked() {
        let rows = Stacks.layout([pr("x1", head: "fix", base: "main")])
        XCTAssertEqual(rows.first?.isStacked, false)
        XCTAssertEqual(rows.first?.depth, 0)
    }

    func testSameBranchNamesInDifferentReposDoNotLink() {
        let a = pr("a1", head: "feat", base: "main", repo: "o/one")
        let b = pr("b2", head: "next", base: "feat", repo: "o/two")
        XCTAssertTrue(Stacks.layout([a, b]).allSatisfy { !$0.isStacked })
    }

    func testRedStackSortsAboveGreenStandalone() {
        let green = pr("g1", head: "g", base: "main", state: .success, updated: .now)
        let bottom = pr("b1", head: "s1", base: "main", state: .success, updated: .distantPast)
        let topRed = pr("t2", head: "s2", base: "s1", state: .failure, updated: .distantPast)
        XCTAssertEqual(Stacks.layout([green, bottom, topRed]).map(\.id), ["b1", "t2", "g1"])
    }

    func testCycleStillEmitsEveryPR() {
        let a = pr("a1", head: "x", base: "y")
        let b = pr("b2", head: "y", base: "x")
        XCTAssertEqual(Set(Stacks.layout([a, b]).map(\.id)), ["a1", "b2"])
    }

    func testMarkdown() {
        let a = pr("a1", head: "feat-1", base: "main", state: .success)
        let b = pr("b2", head: "feat-2", base: "feat-1", state: .failure)
        let md = Stacks.markdown(Stacks.layout([a, b]))
        XCTAssertEqual(md, "- 🟢 [#1](https://github.com/o/r/pull/1) T a1 `feat-1`\n  - 🔴 [#2](https://github.com/o/r/pull/1) T b2 `feat-2`")
    }

    func testDequeuedTransition() {
        let base = pr("a1", head: "f", base: "main", state: .pending)
        let queued = PullRequest(id: base.id, repo: base.repo, number: base.number, title: base.title, url: base.url, isDraft: false,
                                 updatedAt: .now, headSha: "s", checks: base.checks, mergeQueue: MergeQueueInfo(position: 2, state: "QUEUED"))
        XCTAssertEqual(Transitions.events(previous: [queued], current: [base], mode: .failOnly).map(\.kind), [.dequeued])
        XCTAssertEqual(Transitions.events(previous: [base], current: [queued], mode: .all), [])
        XCTAssertEqual(Transitions.events(previous: [queued], current: [base], mode: .off), [])
    }
}
