import Foundation

extension Date {
    /// "4m", "3h", "3d", "2w". Keeps PR rows narrow (US-005).
    var compactAgo: String {
        let s = max(0, Int(Date.now.timeIntervalSince(self)))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(s / 60)m"
        case ..<86_400: return "\(s / 3600)h"
        case ..<604_800: return "\(s / 86_400)d"
        default: return "\(s / 604_800)w"
        }
    }
}
