import Foundation

public enum ColorProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    case standard = "default"
    case deuteranopia

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: "Default"
        case .deuteranopia: "Deuteranopia"
        }
    }
}
