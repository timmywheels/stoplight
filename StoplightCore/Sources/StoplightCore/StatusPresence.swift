import Foundation

/// Which of the three lights are on. Drives the menu bar dots and the small widget.
/// Drafts don't light anything (same rule as `Rollup.aggregate`).
public struct StatusPresence: Equatable, Sendable {
    public let failure: Bool
    public let pending: Bool
    public let success: Bool

    public init(failure: Bool, pending: Bool, success: Bool) {
        self.failure = failure
        self.pending = pending
        self.success = success
    }

    public init(_ prs: [PullRequest]) {
        let states = Set(prs.filter { !$0.isDraft }.map(\.state))
        failure = states.contains(.failure)
        pending = states.contains(.pending)
        success = states.contains(.success)
    }

    public static let dark = StatusPresence(failure: false, pending: false, success: false)
    public var isDark: Bool { self == .dark }
}
