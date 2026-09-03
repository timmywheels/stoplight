import AppKit
import StoplightCore

/// Menu bar image: three horizontal dots, red / yellow / green (US-004).
/// A dot is lit when at least one PR is in that state, dim otherwise. Drawn directly with AppKit.
enum StatusGlyph {
    static let dot: CGFloat = 6
    static let gap: CGFloat = 3
    static let height: CGFloat = 18

    static func image(for presence: StatusPresence, count: Int?, pop: CGFloat = 0) -> NSImage {
        let width = dot * 3 + gap * 2
        let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let lights: [(on: Bool, color: NSColor, pop: CGFloat)] = [
                (presence.failure, .systemRed, 0),
                (presence.pending, .systemYellow, 0),
                (presence.success, .systemGreen, pop),
            ]
            for (i, light) in lights.enumerated() {
                let x = CGFloat(i) * (dot + gap)
                let grow = light.on ? light.pop : 0
                let rect = NSRect(x: x - grow / 2, y: (height - dot) / 2 - grow / 2, width: dot + grow, height: dot + grow)
                let color = light.on ? light.color : NSColor.secondaryLabelColor.withAlphaComponent(0.35)
                color.setFill()
                NSBezierPath(ovalIn: rect).fill()
            }
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = describe(presence)
        guard let count else { return img }
        return withBadge(img, text: "\(count)")
    }

    private static func describe(_ p: StatusPresence) -> String {
        var parts: [String] = []
        if p.failure { parts.append("failing") }
        if p.pending { parts.append("running") }
        if p.success { parts.append("passing") }
        return parts.isEmpty ? "No PRs" : "PRs " + parts.joined(separator: ", ")
    }

    private static func withBadge(_ img: NSImage, text: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let str = NSAttributedString(string: text, attributes: attrs)
        let textSize = str.size()
        let size = NSSize(width: img.size.width + 4 + textSize.width, height: max(img.size.height, textSize.height))
        let out = NSImage(size: size, flipped: false) { rect in
            img.draw(in: NSRect(x: 0, y: (rect.height - img.size.height) / 2, width: img.size.width, height: img.size.height))
            str.draw(at: NSPoint(x: img.size.width + 4, y: (rect.height - textSize.height) / 2))
            return true
        }
        out.isTemplate = false
        return out
    }
}
