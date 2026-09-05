import AppKit
import SwiftUI
import StoplightCore

/// The circular buttons in an expanded row (US-031). Users pick which appear and in what order.
enum RowAction: String, CaseIterable, Identifiable, Codable {
    case open, run, checks, copyURL, share, copyBranch, copyHash, pin, fix
    var id: String { rawValue }

    static let defaultOrder: [RowAction] = [.open, .run, .copyURL, .share, .copyHash, .pin, .fix]

    var title: String {
        switch self {
        case .open: "Open on GitHub"
        case .run: "Actions run summary"
        case .checks: "Checks tab"
        case .copyURL: "Copy URL"
        case .share: "Share (title as a link)"
        case .copyBranch: "Copy branch name"
        case .copyHash: "Copy commit hash"
        case .pin: "Pin"
        case .fix: "Fix with your agent"
        }
    }

    var symbol: String {
        switch self {
        case .open: "arrow.up.right"
        case .run: "list.bullet.rectangle"
        case .checks: "checklist"
        case .copyURL: "doc.on.doc"
        case .share: "square.and.arrow.up"
        case .copyBranch: "arrow.triangle.branch"
        case .copyHash: "number"
        case .pin: "pin"
        case .fix: "sparkles"
        }
    }

    /// Whether this button makes sense for the row right now.
    @MainActor
    func isAvailable(for pr: PullRequest, model: AppModel) -> Bool {
        switch self {
        case .open, .copyURL, .share, .pin: true
        case .run: pr.actionsRunURL != nil
        case .checks: !pr.checks.isEmpty
        case .copyBranch: !pr.headRefName.isEmpty
        case .copyHash: !pr.headSha.isEmpty
        case .fix: pr.state == .failure && model.canFix(pr) && !pr.isBranch
        }
    }
}
