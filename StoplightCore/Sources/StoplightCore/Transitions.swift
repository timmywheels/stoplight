import Foundation

public enum NotificationMode: String, Codable, Sendable {
    case all
    case failOnly
    case off
}

/// Something worth telling the user about (US-006).
public struct CIEvent: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case failed, passed, dequeued, deployFailed, deployed }

    public let pr: PullRequest
    public let kind: Kind

    /// One notification per (PR, head commit, kind). A new push changes the sha and resets this.
    public var key: String { "\(pr.id)|\(pr.headSha)|\(kind.rawValue)" }
    public var id: String { key }

    public var title: String { pr.shortRef }
    public var body: String {
        switch kind {
        case .failed:
            if let first = pr.failingChecks.first { return "\(pr.title)\n\(first.name) failed" }
            return pr.title
        case .passed:
            return "\(pr.title)\nAll checks passed"
        case .dequeued:
            return "\(pr.title)\nRemoved from the merge queue"
        case .deployFailed:
            if let first = pr.failingChecks.first { return "\(pr.title)\n\(first.name) failed after merge" }
            return "\(pr.title)\nChecks failed after merge"
        case .deployed:
            return "\(pr.title)\nMerged and green"
        }
    }
    public var url: URL { pr.url }
}

/// Pure transition table. No side effects, fully unit-tested.
public enum Transitions {
    /// - previous: the visible list from the last poll (already filtered for hidden repos)
    /// - current:  the visible list now
    public static func events(previous: [PullRequest], current: [PullRequest], mode: NotificationMode) -> [CIEvent] {
        guard mode != .off else { return [] }
        let prevByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        var out: [CIEvent] = []

        // Merged PRs (US-022): the merge commit's checks on the base branch.
        for pr in current where pr.status == .merged {
            guard let prev = prevByID[pr.id], prev.status == .merged else { continue }
            switch (prev.state, pr.state) {
            case (.failure, .failure): continue
            case (_, .failure): out.append(CIEvent(pr: pr, kind: .deployFailed))
            case (.pending, .success) where mode == .all: out.append(CIEvent(pr: pr, kind: .deployed))
            default: continue
            }
        }

        for pr in current where !pr.isDraft && pr.status == .open {
            // Unknown before now (first launch, newly opened, newly watched): nothing to compare against.
            guard let prev = prevByID[pr.id] else { continue }

            // Merge queue kicked it out (US-016). Fires in both non-off modes; it's a failure in spirit.
            if prev.mergeQueue != nil, pr.mergeQueue == nil {
                out.append(CIEvent(pr: pr, kind: .dequeued))
            }
            // New push: treat the old state as "pending" so a fresh red or green fires.
            let prevState: CIState = prev.headSha == pr.headSha ? prev.state : .pending

            switch (prevState, pr.state) {
            case (.failure, .failure):
                continue
            case (_, .failure):
                out.append(CIEvent(pr: pr, kind: .failed))
            case (.pending, .success) where mode == .all:
                out.append(CIEvent(pr: pr, kind: .passed))
            default:
                continue
            }
        }
        return out
    }
}
