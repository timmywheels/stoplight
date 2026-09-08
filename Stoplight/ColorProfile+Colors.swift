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
        case .standard: defaultColor
        case .deuteranopia:
            switch state {
            case .success: .systemBlue
            default: defaultColor
            }
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
