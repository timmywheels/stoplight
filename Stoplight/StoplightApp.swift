import SwiftUI
import StoplightCore

@main
struct StoplightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The status item and its panel are AppKit (see StatusPanelController). SwiftUI owns Settings only.
        Settings {
            SettingsView(model: AppModel.shared)
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
}
