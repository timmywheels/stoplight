import XCTest
@testable import StoplightCore

final class PrefsTests: XCTestCase {
    private func pr(id: String, repo: String = "o/r", state: CheckState = .success) -> PullRequest {
        PullRequest(id: id, repo: repo, number: 1, title: "t", url: URL(string: "https://github.com/\(repo)/pull/1")!,
                    isDraft: false, updatedAt: .now, headSha: "s", checks: [CheckResult(name: "ci", state: state, url: nil)])
    }

    // US-010 / US-013
    func testIgnoredRepoDoesNotTurnAggregateRed() {
        let prs = [pr(id: "a", repo: "noisy/repo", state: .failure), pr(id: "b", repo: "o/r", state: .success)]
        let visible = Filters.visible(prs, ignore: IgnoreRules(repos: ["Noisy/Repo"]))
        XCTAssertEqual(visible.map(\.id), ["b"])
        XCTAssertEqual(Rollup.aggregate(visible), .success)
    }

    func testHideBots() {
        let bot = PullRequest(id: "bot", repo: "acme/x", number: 1, title: "t", url: URL(string: "https://github.com/acme/x/pull/1")!,
                              isDraft: false, updatedAt: .now, headSha: "s", checks: [], author: "dependabot[bot]")
        let human = pr(id: "h", repo: "acme/y")
        XCTAssertEqual(Filters.visible([bot, human], ignore: IgnoreRules(hideBots: true)).map(\.id), ["h"])
        XCTAssertEqual(Filters.visible([bot, human], ignore: IgnoreRules(hideBots: false)).map(\.id), ["bot", "h"])
    }

    func testQueryStringsAndBatching() {
        XCTAssertEqual(PRQuery.author("bob").githubSearch, "is:pr is:open archived:false author:bob")
        XCTAssertEqual(PRQuery.repo("acme/api").githubSearch, "is:pr is:open archived:false repo:acme/api")
        XCTAssertEqual(PRQuery.org("acme").githubSearch, "is:pr is:open archived:false org:acme")
        let q = GitHubProvider.searchQuery([.authored, .author("bob")])
        XCTAssertTrue(q.contains("q0: search(query: \"is:pr is:open archived:false author:@me\""))
        XCTAssertTrue(q.contains("q1: search(query: \"is:pr is:open archived:false author:bob\""))
    }

    func testIdentifierValidation() {
        XCTAssertTrue(Filters.isValidLogin("timmywheels"))
        XCTAssertFalse(Filters.isValidLogin("-bad"))
        XCTAssertFalse(Filters.isValidLogin("a b"))
        XCTAssertTrue(Filters.isValidRepo("acme/api.v2"))
        XCTAssertFalse(Filters.isValidRepo("acme"))
        XCTAssertFalse(Filters.isValidRepo("acme/api/extra"))
    }

    // US-011
    func testPRRefParsesGitHubURLs() {
        XCTAssertEqual(PRRef(url: URL(string: "https://github.com/acme/api/pull/412")!)?.key, "acme/api#412")
        XCTAssertEqual(PRRef(url: URL(string: "https://github.com/acme/api/pull/412/files?diff=split#top")!)?.key, "acme/api#412")
        XCTAssertNil(PRRef(url: URL(string: "https://github.com/acme/api/issues/412")!))
        XCTAssertNil(PRRef(url: URL(string: "https://gitlab.com/acme/api/pull/412")!))
        XCTAssertNil(PRRef(url: URL(string: "https://github.com/acme/api/pull/abc")!))
    }

    func testPRRefRejectsInjection() {
        XCTAssertNil(PRRef(owner: "a\") { x }", name: "b", number: 1))
        XCTAssertNil(PRRef(owner: "a", name: "b", number: 0))
        XCTAssertEqual(PRRef(key: "acme/api#7")?.number, 7)
        XCTAssertNil(PRRef(key: "acme#7"))
    }

    func testRefsQueryUsesAliases() {
        let q = GitHubProvider.refsQuery([PRRef(owner: "a", name: "b", number: 1)!, PRRef(owner: "c", name: "d", number: 2)!])
        XCTAssertTrue(q.contains("r0: repository(owner: \"a\", name: \"b\") { pullRequest(number: 1)"))
        XCTAssertTrue(q.contains("r1: repository(owner: \"c\", name: \"d\") { pullRequest(number: 2)"))
        XCTAssertTrue(q.contains("fragment PRFields"))
    }

    // US-012
    func testPinnedSortFirstThenWorstFirst() {
        let prs = [pr(id: "a", state: .failure), pr(id: "b", state: .success), pr(id: "c", state: .pending)]
        XCTAssertEqual(Rollup.sorted(prs, pinnedFirst: ["b"]).map(\.id), ["b", "a", "c"])
    }

    func testOldSnapshotStillDecodes() throws {
        let json = """
        {"writtenAt":"2026-09-03T20:44:18Z","prs":[{"repo":"o/r","id":"x","url":"https://github.com/o/r/pull/1","isDraft":false,"number":1,"title":"t","headSha":"s","checks":[],"updatedAt":"2026-09-03T09:10:38Z"}]}
        """
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let snap = try dec.decode(Snapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.prs.first?.author, "")
        XCTAssertEqual(snap.prs.first?.status, .open)
        XCTAssertEqual(snap.pinnedIDs, [])
    }
}
