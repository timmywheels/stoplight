import SwiftUI
import StoplightCore

@main
struct StoplightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The status item and its panel are AppKit (see StatusPanelController). SwiftUI owns Settings only.
        Settings {
            SettingsView(model: AppModel.shared)
                .environment(\.colorProfile, AppModel.shared.prefs.colorProfile)
        }
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusPanel: StatusPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        model.start()  // polling + snapshot server, at launch, not on first click
        statusPanel = StatusPanelController(model: model)
    }

    /// stoplight://open            → show the panel (small widget)
    /// stoplight://pr/<PR node id> → show the panel with that PR selected and expanded
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "stoplight" {
            let model = AppModel.shared
            let parts = url.pathComponents.dropFirst()
            if url.host == "pr", let id = parts.first {
                model.reveal(prID: id)
                model.openPanel?()
            } else if url.host == "agent", parts.count >= 2 {
                // stoplight://agent/<working|attention|done>/<PR id>  (from Claude Code hooks or the agent itself)
                model.agentReported(parts[parts.startIndex], prID: parts[parts.startIndex + 1])
            } else {
                model.openPanel?()
            }
        }
    }
}
