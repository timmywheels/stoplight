import Foundation

public enum Rollup {
    /// FR-4: exactly one state per PR. Failure wins, then pending, then success. No checks means `.none`.
    /// One check run, with what it belongs to and when it ran.
    public struct TimedCheck: Sendable {
        public let check: CheckResult
        /// The workflow the run came from. Two workflows can define a job of the same name,
        /// and those are genuinely different checks.
        public let workflow: String
        public let at: Date?
        public init(check: CheckResult, workflow: String, at: Date?) {
            self.check = check; self.workflow = workflow; self.at = at
        }
    }

    /// Newest run per (workflow, check name), in the order the names first appeared.
    /// Without this, a re-run leaves its failed predecessor attached to the commit and the PR
    /// reads red while GitHub shows it green.
    public static func newestPerCheck(_ items: [TimedCheck]) -> [CheckResult] {
        var best: [String: TimedCheck] = [:]
        var order: [String] = []
        for item in items {
            let key = item.workflow + "\u{1}" + item.check.name
            guard let current = best[key] else {
                best[key] = item
                order.append(key)
                continue
            }
            // Undated runs fall back to position: GitHub returns them oldest first.
            if (item.at ?? .distantPast) >= (current.at ?? .distantPast) { best[key] = item }
        }
        return order.compactMap { best[$0]?.check }
    }

    public static func state(for checks: [CheckResult]) -> CIState {
        if checks.isEmpty { return .none }
        if checks.contains(where: { $0.state == .failure }) { return .failure }
        if checks.contains(where: { $0.state == .pending }) { return .pending }
        // Skipped and neutral don't prove anything. Green means something actually passed, otherwise
        // a PR whose only check was skipped would read as verified when nothing ran.
        return checks.contains { $0.state == .success } ? .success : .none
    }

    /// FR-5: menu bar color is the worst state across non-draft PRs. Empty list is `.none`.
    public static func aggregate(_ prs: [PullRequest]) -> CIState {
        prs.filter { !$0.isDraft }.map(\.state).min() ?? .none
    }

    /// Dropdown sort: worst state first, then most recently updated (US-005).
    public static func sorted(_ prs: [PullRequest]) -> [PullRequest] {
        prs.sorted {
            if $0.state != $1.state { return $0.state < $1.state }
            return $0.updatedAt > $1.updatedAt
        }
    }

    /// US-012: pinned PRs first (each group still worst-first).
    public static func sorted(_ prs: [PullRequest], pinnedFirst pinned: Set<String>) -> [PullRequest] {
        let p = sorted(prs.filter { pinned.contains($0.id) })
        let rest = sorted(prs.filter { !pinned.contains($0.id) })
        return p + rest
    }
}
