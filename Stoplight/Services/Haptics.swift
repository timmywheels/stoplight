import AppKit

/// A tick on a Force Touch trackpad, felt only while a finger is on it, so it confirms what you just
/// clicked or dragged and nothing else. People who turned trackpad feedback off in System Settings get none.
enum Haptics {
    /// A dragged section lines up with a new spot.
    static func snap() { perform(.alignment) }
    /// Something done that has no other feel to it: copied, picked, dropped.
    static func tick() { perform(.generic) }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        // Settings → General → Trackpad ticks (UserPrefs.haptics), read here so callers needn't pass prefs.
        guard UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
