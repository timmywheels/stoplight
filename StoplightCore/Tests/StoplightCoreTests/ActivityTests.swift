import XCTest
@testable import StoplightCore

final class ActivityTests: XCTestCase {
    private let url = URL(string: "https://github.com/o/r/pull/1")!
    private func a(_ id: String, _ kind: Activity.Kind = .comment, by author: String = "ana", bot: Bool = false, at t: TimeInterval, body: String = "Looks good") -> Activity {
        Activity(id: id, kind: kind, author: author, isBot: bot, body: body, at: Date(timeIntervalSince1970: t), url: url.appendingPathComponent(id))
    }
    private func pr(_ activity: [Activity], author: String = "me", status: PRStatus = .open) -> PullRequest {
        PullRequest(id: "p", repo: "o/r", number: 1, title: "Title", url: url, isDraft: false, updatedAt: .now, headSha: "s",
                    checks: [], author: author, status: status, activity: activity)
    }
    private func events(_ prev: [Activity], _ cur: [Activity], rules: ActivityRules = ActivityRules(), author: String = "me") -> [CIEvent] {
        Transitions.activityEvents(previous: [pr(prev, author: author)], current: [pr(cur, author: author)], me: "me", rules: rules)
    }

    func testNewCommentFires() {
        let e = events([a("c1", at: 1)], [a("c1", at: 1), a("c2", at: 2, body: "Can we rename this?")])
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].title, "ana commented · o/r #1")
        XCTAssertEqual(e[0].body, "Title\n\u{201C}Can we rename this?\u{201D}")
        XCTAssertEqual(e[0].url.lastPathComponent, "c2") // opens at the comment
    }

    func testNothingNewIsSilent() {
        XCTAssertTrue(events([a("c1", at: 1)], [a("c1", at: 1)]).isEmpty)
    }

    func testFirstSightingIsSilent() {
        let e = Transitions.activityEvents(previous: [], current: [pr([a("c1", at: 1)])], me: "me", rules: ActivityRules())
        XCTAssertTrue(e.isEmpty)
    }

    func testYourOwnCommentsAreSilent() {
        XCTAssertTrue(events([], [a("c1", by: "Me", at: 1)]).isEmpty)
    }

    func testBotsAreIgnoredByDefault() {
        XCTAssertTrue(events([], [a("c1", by: "coderabbitai", bot: true, at: 1), a("c2", by: "renovate[bot]", at: 2)]).isEmpty)
        XCTAssertEqual(events([], [a("c1", by: "coderabbitai", bot: true, at: 1)], rules: ActivityRules(ignoreBots: false)).count, 1)
    }

    func testIgnoreListIsCaseInsensitiveAndBotSuffixOptional() {
        let rules = ActivityRules(ignoreBots: false, ignoredAuthors: ["Vercel[bot]", "linear"])
        XCTAssertTrue(events([], [a("c1", by: "vercel", bot: true, at: 1), a("c2", by: "LINEAR", at: 2)], rules: rules).isEmpty)
        XCTAssertEqual(events([], [a("c3", by: "bo", at: 3)], rules: rules).count, 1)
    }

    func testSeveralBecomeOneNotification() {
        let e = events([], [a("r1", .changesRequested, by: "ana", at: 1), a("c1", by: "bo", at: 2), a("c2", by: "ana", at: 3)])
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].body, "Title\n1 review and 2 comments from ana, bo")
        XCTAssertTrue(e[0].urgent) // changes requested makes a sound
        XCTAssertEqual(e[0].url, url)
    }

    func testTogglesSplitReviewsFromComments() {
        let items = [a("r1", .approved, at: 1), a("c1", at: 2)]
        XCTAssertEqual(events([], items, rules: ActivityRules(reviews: true, comments: false))[0].activity.map(\.id), ["r1"])
        XCTAssertEqual(events([], items, rules: ActivityRules(reviews: false, comments: true))[0].activity.map(\.id), ["c1"])
        XCTAssertTrue(events([], items, rules: .off).isEmpty)
    }

    func testOnlyYourPRs() {
        let rules = ActivityRules(onlyAuthor: "me")
        XCTAssertEqual(events([], [a("c1", at: 1)], rules: rules).count, 1)
        XCTAssertTrue(events([], [a("c1", at: 1)], rules: rules, author: "someone").isEmpty)
    }

    func testOldItemReturningToTheWindowIsSilent() {
        // "last 10" can push an old comment out and let it back in: it isn't new.
        XCTAssertTrue(events([a("c5", at: 5)], [a("c1", at: 1), a("c5", at: 5)]).isEmpty)
    }

    func testKeyChangesWithEachNewItem() {
        let one = events([], [a("c1", at: 1)])[0].key, two = events([a("c1", at: 1)], [a("c1", at: 1), a("c2", at: 2)])[0].key
        XCTAssertNotEqual(one, two)
    }
}
