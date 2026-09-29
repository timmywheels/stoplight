import Foundation

public enum NotificationMode: String, Codable, Sendable {
    case all
    case failOnly
    case off
}

/// Something worth telling the user about (US-006).
public struct CIEvent: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case failed, passed, dequeued, deployFailed, deployed, branchMoved, agentAttention, agentDone, approved, changesRequested, activity }

    public let pr: PullRequest
    public let kind: Kind
    /// Extra context for kinds that need it (branchMoved: the previous branch name).
    public let detail: String?

    /// New reviews and comments (kind .activity), oldest first.
    public let activity: [Activity]

    public init(pr: PullRequest, kind: Kind, detail: String? = nil) { self.pr = pr; self.kind = kind; self.detail = detail; self.activity = [] }

    /// Reviews and comments that just arrived on `pr`.
    public init(pr: PullRequest, activity: [Activity]) {
        self.pr = pr; self.kind = .activity; self.detail = nil; self.activity = activity.sorted { $0.at < $1.at }
    }

    /// One notification per (PR, head commit, kind); for activity, per newest item. A new push changes the sha and resets this.
    public var key: String { "\(pr.id)|\(pr.headSha)|\(kind.rawValue)" + (activity.last.map { "|\($0.id)" } ?? "") }

    /// Changes requested (by decision or in a review) makes a sound; other review news arrives quietly.
    public var urgent: Bool {
        switch kind {
        case .passed, .branchMoved, .agentDone: false
        case .activity: activity.contains { $0.kind == .changesRequested }
        default: true
        }
    }
    public var id: String { key }

    public var title: String {
        switch kind {
        case .branchMoved: "New release branch in \(pr.repo)"
        case .agentAttention: "Agent needs you · \(pr.shortRef)"
        case .agentDone: "Agent done · \(pr.shortRef)"
        case .activity where activity.count == 1: "\(activity[0].author) \(Self.verb(activity[0].kind)) · \(pr.shortRef)"
        default: pr.shortRef
        }
    }
    public var body: String {
        switch kind {
        case .failed:
            if let first = pr.failingChecks.first { return "\(pr.title)\n\(first.name) failed" }
            return pr.title
        case .passed:
            return "\(pr.title)\nAll checks passed"
        case .dequeued:
            return "\(pr.title)\nRemoved from the merge queue"
        case .approved:
            return "\(pr.title)\nApproved"
        case .changesRequested:
            return "\(pr.title)\nChanges requested"
        case .deployFailed:
            if let first = pr.failingChecks.first { return "\(pr.title)\n\(first.name) failed after merge" }
            return "\(pr.title)\nChecks failed after merge"
        case .deployed:
            return "\(pr.title)\nMerged and green"
        case .branchMoved:
            return "Now following \(pr.headRefName)" + (detail.map { " (was \($0))" } ?? "")
        case .agentAttention:
            return "\(detail ?? "Your agent") needs your input on \(pr.title)"
        case .agentDone:
            return "\(detail ?? "Your agent") finished on \(pr.title)"
        case .activity:
            if activity.count == 1 {
                let words = Self.excerpt(activity[0].body)
                return words.isEmpty ? pr.title : "\(pr.title)\n\u{201C}\(words)\u{201D}"
            }
            var who: [String] = []
            for a in activity where !who.contains(a.author) { who.append(a.author) }
            let reviews = activity.filter { $0.kind != .comment }.count, comments = activity.count - reviews
            let what = [reviews > 0 ? "\(reviews) review\(reviews == 1 ? "" : "s")" : nil,
                        comments > 0 ? "\(comments) comment\(comments == 1 ? "" : "s")" : nil].compactMap { $0 }.joined(separator: " and ")
            return "\(pr.title)\n\(what) from \(who.prefix(3).joined(separator: ", "))" + (who.count > 3 ? " and \(who.count - 3) more" : "")
        }
    }
    /// A single comment opens right at it; several open the PR.
    public var url: URL { activity.count == 1 ? activity[0].url : pr.url }

    static func verb(_ k: Activity.Kind) -> String {
        switch k {
        case .approved: "approved"
        case .changesRequested: "requested changes"
        case .reviewed: "reviewed"
        case .comment: "commented"
        }
    }

    /// One line, at most ~140 characters.
    static func excerpt(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return line.count > 140 ? String(line.prefix(140)).trimmingCharacters(in: .whitespaces) + "…" : line
    }
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

            // Review moved (US-042). Approval only in .all; changes requested is bad news, so both modes.
            if prev.review != pr.review {
                if pr.review == .changesRequested { out.append(CIEvent(pr: pr, kind: .changesRequested)) }
                if pr.review == .approved, mode == .all { out.append(CIEvent(pr: pr, kind: .approved)) }
            }
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
