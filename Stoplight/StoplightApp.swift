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
        model.prefs.appearance.apply()
        model.start()  // polling + snapshot server, at launch, not on first click
        statusPanel = StatusPanelController(model: model)
        // First run: show the panel now, not after the first refresh. If sign-in fails or the dots are
        // behind the notch, a launch that shows nothing reads as "it didn't open".
        if !model.prefs.tourSeen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.openPanel?() }
        }
    }

    /// Opening the app again (Finder, Spotlight, Launchpad) while it's running: show the panel.
    /// The only way in when the dots are hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppModel.shared.openPanel?()
        return false
    }

    /// stoplight://open            → show the panel (small widget)
    /// stoplight://pr/<PR node id> → show the panel with that PR selected and expanded
    /// stoplight://search?q=<text> → show the panel searching for <text> (a commit hash, a PR link, author:…)
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "stoplight" {
            let model = AppModel.shared
            let parts = url.pathComponents.dropFirst()
            if url.host == "pr", let id = parts.first {
                model.reveal(prID: id)
                model.openPanel?()
            } else if url.host == "search" {
                let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
                model.tab = .prs
                model.isSearching = true
                model.searchText = q.trimmingCharacters(in: .whitespacesAndNewlines)
                model.openPanel?()
            } else {
                model.openPanel?()
            }
        }
    }
}
