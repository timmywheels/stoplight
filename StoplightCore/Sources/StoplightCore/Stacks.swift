import Foundation

/// A PR laid out inside its stack (US-015). `depth` 0 is the bottom of the stack (closest to trunk).
public struct StackRow: Identifiable, Sendable, Equatable {
    public let pr: PullRequest
    public let depth: Int
    /// id of the bottom PR in this stack; nil for a PR that isn't stacked on or under anything visible.
    public let stackID: String?
    public var id: String { pr.id }
    public var isStacked: Bool { stackID != nil }
}

public enum Stacks {
    /// Groups PRs whose base branch is another visible PR's head branch (same repo).
    /// Stacks are emitted bottom-up as contiguous runs. Groups are ordered worst-state first, then most recent.
    public static func layout(_ prs: [PullRequest]) -> [StackRow] {
        var byHead: [String: PullRequest] = [:]
        for pr in prs where !pr.headRefName.isEmpty { byHead["\(pr.repo.lowercased())#\(pr.headRefName)"] = pr }

        func parent(of pr: PullRequest) -> PullRequest? {
            guard !pr.baseRefName.isEmpty, let p = byHead["\(pr.repo.lowercased())#\(pr.baseRefName)"], p.id != pr.id else { return nil }
            return p
        }
        var children: [String: [PullRequest]] = [:]
        var roots: [PullRequest] = []
        for pr in prs {
            if let p = parent(of: pr) { children[p.id, default: []].append(pr) } else { roots.append(pr) }
        }

        func subtree(_ pr: PullRequest, depth: Int, stackID: String?, visited: inout Set<String>) -> [StackRow] {
            guard visited.insert(pr.id).inserted else { return [] }
            var rows = [StackRow(pr: pr, depth: depth, stackID: stackID)]
            for c in Rollup.sorted(children[pr.id] ?? []) {
                rows += subtree(c, depth: depth + 1, stackID: stackID ?? pr.id, visited: &visited)
            }
            return rows
        }
        func worst(_ rows: [StackRow]) -> CIState { rows.map(\.pr.state).min() ?? .none }

        var visited = Set<String>()
        var groups: [[StackRow]] = []
        for root in roots {
            let hasKids = !(children[root.id] ?? []).isEmpty
            groups.append(subtree(root, depth: 0, stackID: hasKids ? root.id : nil, visited: &visited))
        }
        // Cycles (A based on B, B based on A) never reach `roots`; emit them flat so nothing disappears.
        for pr in prs where !visited.contains(pr.id) { groups.append(subtree(pr, depth: 0, stackID: nil, visited: &visited)) }

        groups.sort { a, b in
            let (wa, wb) = (worst(a), worst(b))
            if wa != wb { return wa < wb }
            return (a.first?.pr.updatedAt ?? .distantPast) > (b.first?.pr.updatedAt ?? .distantPast)
        }
        return groups.flatMap { $0 }
    }

    /// The rows belonging to one stack, bottom-up.
    public static func members(of stackID: String, in rows: [StackRow]) -> [StackRow] {
        rows.filter { $0.stackID == stackID }
    }

    /// Shareable summary, bottom-up. One line per PR: status, link, title, branch.
    public static func markdown(_ rows: [StackRow]) -> String {
        rows.map { row in
            let icon: String = switch row.pr.state {
            case .failure: "🔴"
            case .pending: "🟡"
            case .success: "🟢"
            case .none: "⚪️"
            }
            let indent = String(repeating: "  ", count: row.depth)
            return "\(indent)- \(icon) [#\(row.pr.number)](\(row.pr.url.absoluteString)) \(row.pr.title) `\(row.pr.headRefName)`"
        }.joined(separator: "\n")
    }
}
