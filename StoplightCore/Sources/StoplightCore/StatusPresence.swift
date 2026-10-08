import Foundation

/// Which of the three lights are on. Drives the menu bar dots and the small widget.
/// The same PRs the panel's footer counts: open ones, drafts included, by the color of their dot.
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
        let states = Set(prs.filter(\.isCounted).map(\.effectiveState))
        failure = states.contains(.failure)
        pending = states.contains(.pending)
        success = states.contains(.success)
    }

    public static let dark = StatusPresence(failure: false, pending: false, success: false)
    public var isDark: Bool { self == .dark }
}
