import AppKit
import SwiftUI
import StoplightCore

/// The circular buttons in an expanded row (US-031). Users pick which appear and in what order.
enum RowAction: String, CaseIterable, Identifiable, Codable {
    case open, run, checks, queue, copyURL, share, copyBranch, copyHash, pin
    var id: String { rawValue }

    static let defaultOrder: [RowAction] = [.open, .run, .queue, .copyURL, .share, .copyHash, .pin]

    var title: String {
        switch self {
        case .open: "Open on GitHub"
        case .run: "Actions run summary"
        case .checks: "Checks tab"
        case .queue: "Merge queue"
        case .copyURL: "Copy URL"
        case .share: "Share (title as a link)"
        case .copyBranch: "Copy branch name"
        case .copyHash: "Copy commit hash"
        case .pin: "Pin"
        }
    }

    var symbol: String {
        switch self {
        case .open: "arrow.up.right"
        case .run: "list.bullet.rectangle"
        case .checks: "checklist"
        case .queue: "line.3.horizontal"
        case .copyURL: "doc.on.doc"
        case .share: "square.and.arrow.up"
        case .copyBranch: "arrow.triangle.branch"
        case .copyHash: "number"
        case .pin: "pin"
        }
    }

    /// Whether this button makes sense for the row right now.
    @MainActor
    func isAvailable(for pr: PullRequest, model: AppModel) -> Bool {
        switch self {
        case .open, .copyURL, .share, .pin: true
        case .run: pr.actionsRunURL != nil
        case .checks: !pr.checks.isEmpty
        case .queue: pr.queueURL != nil
        case .copyBranch: !pr.headRefName.isEmpty
        case .copyHash: !pr.headSha.isEmpty
        }
    }
}
