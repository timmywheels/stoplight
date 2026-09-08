import AppKit
import StoplightCore
import SwiftUI

extension ColorProfile {
    func color(for state: CIState) -> Color {
        Color(nsColor: nsColor(for: state))
    }

    func nsColor(for state: CIState) -> NSColor {
        let defaultColor: NSColor = switch state {
        case .failure: .systemRed
        case .pending: .systemYellow
        case .success: .systemGreen
        case .none: .secondaryLabelColor
        }

        switch self {
        case .standard:
            return defaultColor
        case .deuteranopia:
            // Red/green is the hard pair, so success moves to blue and failure stays red.
            return state == .success ? .systemBlue : defaultColor
        }
    }
}

private struct ColorProfileKey: EnvironmentKey {
    static let defaultValue = ColorProfile.standard
}

extension EnvironmentValues {
    var colorProfile: ColorProfile {
        get { self[ColorProfileKey.self] }
        set { self[ColorProfileKey.self] = newValue }
    }
}
