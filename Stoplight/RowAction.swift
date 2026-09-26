import AppKit
import SwiftUI
import StoplightCore

/// The circular buttons in an expanded row (US-031). Users pick which appear and in what order.
enum RowAction: String, CaseIterable, Identifiable, Codable {
    case open, run, checks, queue, copyURL, share, copyBranch, copyHash, pin, fix, review, onramp
    var id: String { rawValue }

    static let defaultOrder: [RowAction] = [.open, .onramp, .run, .queue, .copyURL, .share, .copyHash, .pin, .fix, .review]

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
        case .fix: "Fix with your agent"
        case .review: "Adversarial review with your agent"
        case .onramp: "Review in Onramp"
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
        case .fix: "wrench.and.screwdriver"
        case .review: "eye.trianglebadge.exclamationmark"
        case .onramp: Self.onrampSymbol
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
        case .fix: pr.state == .failure && model.canRunAgent(pr)
        case .review: model.canRunAgent(pr) && !pr.isBranch && pr.status == .open
        case .onramp: !pr.isBranch && PRActions.onrampInstalled
        }
    }
}

extension RowAction {
    /// Not an SF Symbol: Onramp's app icon in outline (see `symbolImage`).
    static let onrampSymbol = "onramp"

    /// The image for a row button's symbol: an SF Symbol, or the Onramp glyph.
    static func symbolImage(_ symbol: String) -> Image {
        symbol == onrampSymbol ? Image(nsImage: onrampGlyph).renderingMode(.template) : Image(systemName: symbol)
    }

    /// Onramp's icon, a rounded square with a road curving through it, drawn
    /// as an outline to sit with the SF Symbols (the same road as Onramp's menu bar icon).
    private static let onrampGlyph: NSImage = {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in
            let box = NSRect(x: 0.5, y: 0.5, width: 13, height: 13)
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: box.minX + x * box.width, y: box.maxY - y * box.height) }
            let road = NSBezierPath()
            road.move(to: p(0.32, -0.05))
            road.curve(to: p(0.84, 1.05), controlPoint1: p(0.32, 0.45), controlPoint2: p(0.84, 0.55))
            road.lineWidth = 2.1
            let square = NSBezierPath(roundedRect: box, xRadius: 3.4, yRadius: 3.4)
            NSColor.black.set()
            NSGraphicsContext.saveGraphicsState()
            square.addClip(); road.stroke()
            NSGraphicsContext.restoreGraphicsState()
            let outline = NSBezierPath(roundedRect: box.insetBy(dx: 0.65, dy: 0.65), xRadius: 2.8, yRadius: 2.8)
            outline.lineWidth = 1.3; outline.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
