import AppKit
import OSLog

private let log = Logger(subsystem: "com.timwheeler.stoplight", category: "Haptics")

/// Feedback on a Force Touch trackpad, felt only while a finger is on it, so it confirms what you just
/// clicked or dragged and nothing else. People who turned trackpad feedback off in System Settings get none.
enum Haptics {
    /// A dragged section lines up with a new spot. Mid-drag, so it's felt as it happens.
    static func snap() { perform(.alignment) }
    /// A dragged section dropped into place.
    static func drop() { perform(.generic) }
    /// A click that did something: copied, opened, pinned, picked. A button acts on release, the moment the
    /// trackpad plays its own click-up, which swallows anything played alongside it; a beat later it's felt.
    static func tick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { perform(.levelChange) }
    }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        // Settings → General → Trackpad haptics (UserPrefs.haptics), read here so callers needn't pass prefs.
        let on = UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true
        log.notice("haptic \(String(describing: pattern.rawValue)) on=\(on) appActive=\(NSApp.isActive) keyWindow=\(NSApp.keyWindow != nil)")
        guard on else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
