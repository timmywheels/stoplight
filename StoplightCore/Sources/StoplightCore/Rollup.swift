import Foundation

public enum Rollup {
    /// FR-4: exactly one state per PR. Failure wins, then pending, then success. No checks means `.none`.
    public static func state(for checks: [CheckResult]) -> CIState {
        if checks.isEmpty { return .none }
        if checks.contains(where: { $0.state == .failure }) { return .failure }
        if checks.contains(where: { $0.state == .pending }) { return .pending }
        return .success
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
