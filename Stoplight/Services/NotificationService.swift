import AppKit
import UserNotifications
import StoplightCore

/// US-006. Posts CIEvents as macOS notifications and opens the PR on click.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var askedForPermission = false

    override init() {
        super.init()
        center.delegate = self
    }

    static var mode: NotificationMode {
        NotificationMode(rawValue: UserDefaults.standard.string(forKey: Prefs.notifications) ?? "all") ?? .all
    }

    /// Called after the first successful fetch, not on launch (spec).
    func requestAuthorizationIfNeeded() async {
        guard !askedForPermission, Self.mode != .off else { return }
        askedForPermission = true
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func post(_ event: CIEvent) async {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.userInfo = ["url": event.url.absoluteString]
        content.threadIdentifier = event.pr.id
        let urgent = event.kind != .passed && event.kind != .branchMoved
        content.sound = urgent ? .default : nil
        content.interruptionLevel = urgent ? .timeSensitive : .active
        let req = UNNotificationRequest(identifier: event.key, content: content, trigger: nil)
        try? await center.add(req)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Menu bar apps are always "foreground"; still show the banner.
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let s = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: s) else { return }
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
    }
}
