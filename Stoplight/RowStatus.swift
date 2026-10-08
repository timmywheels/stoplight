import StoplightCore

/// What a PR row says beyond its dot, as a few glyphs instead of a row of tags: the most urgent
/// first, at most three, each with its words in the tooltip. Nothing the row already shows is
/// repeated: the dot is CI (and hollow for a draft), the Merged section and its check say merged.
/// Ranked by rules: the facts are structured, so rules are instant and never drop the one that matters.
struct RowStatus: Equatable {
    enum Level: Int, Comparable {
        case info, good, waiting, blocking, needsYou // you're the only one who can unblock "needs you"
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }
    /// One fact: an SF Symbol, the words for its tooltip, and how much it matters. `count` sits beside it.
    struct Part: Equatable {
        let symbol: String
        let help: String
        let level: Level
        var count: Int? = nil
    }
    let parts: [Part]
    /// The lead fact is the agent's: clicking the glyphs goes to its terminal.
    let agentLeads: Bool

    /// `reported`: what an agent hook said about this PR ("working", "attention", "done").
    /// `isQueueRow`: the merge queue list, where position is already in the gutter.
    static func of(_ pr: PullRequest, reported: String?, isQueueRow: Bool) -> RowStatus {
        var facts: [Part] = []
        func add(_ symbol: String, _ help: String, _ level: Level, count: Int? = nil) {
            facts.append(Part(symbol: symbol, help: help, level: level, count: count))
        }

        // A followed branch isn't a PR: there's nothing to review or merge, and its dot is its CI.
        if pr.isBranch { return RowStatus(parts: [], agentLeads: false) }
        switch pr.status {
        case .closed:
            return RowStatus(parts: [Part(symbol: "xmark.circle", help: "Closed without merging", level: .info)], agentLeads: false)
        case .merged:
            guard pr.baseState == .failure else { return RowStatus(parts: [], agentLeads: false) }
            return RowStatus(parts: [Part(symbol: "arrow.triangle.branch", help: "Merged; \(pr.baseRefName) is failing right now", level: .blocking)], agentLeads: false)
        case .open:
            break
        }

        let needsYou = reported == "attention"
        if needsYou { add("hand.raised.fill", "Your agent needs you", .needsYou) }
        if pr.mergeState == .conflicting { add("exclamationmark.triangle.fill", "Merge conflicts with \(pr.baseRefName)", .blocking) }
        if let q = pr.mergeQueue, q.isBlocked { add("line.3.horizontal", "Blocked in the merge queue: everything behind it waits", .blocking) }
        if pr.review == .changesRequested { add("exclamationmark.bubble.fill", "Changes requested", .blocking) }
        if let q = pr.mergeQueue, !q.isBlocked, !isQueueRow { add("line.3.horizontal", "Position \(q.position) in the merge queue", .waiting, count: q.position) }
        if !pr.isDraft, pr.review == .reviewRequired { add("person.crop.circle.dashed", "Waiting for review", .waiting) }
        if pr.mergeState == .behind { add("arrow.down.to.line", "Behind \(pr.baseRefName)", .info) }
        if reported == "working" { add("cpu", "An agent is working on it", .info) }
        // Nothing in the way: say so once, with the seal.
        if facts.isEmpty, !pr.isDraft, pr.state != .failure, pr.state != .pending,
           pr.review == .approved || pr.review == .none {
            add("checkmark.seal.fill", pr.review == .approved ? "Approved and nothing failing: ready to merge" : "Nothing failing: ready to merge", .good)
        }

        // The most urgent first; ties keep the order above, which is how much each one blocks.
        let ranked = facts.enumerated().sorted { a, b in
            a.element.level != b.element.level ? a.element.level > b.element.level : a.offset < b.offset
        }.map(\.element)
        let agentLeads = ranked.first.map { $0.symbol == "hand.raised.fill" || $0.symbol == "cpu" } ?? false
        return RowStatus(parts: Array(ranked.prefix(3)), agentLeads: agentLeads)
    }
}
