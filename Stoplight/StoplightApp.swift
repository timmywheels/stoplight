import SwiftUI
import StoplightCore

@main
struct StoplightApp: App {
    @State private var model: AppModel

    init() {
        // Start polling and the snapshot server at launch, not when the popover is first opened.
        let m = AppModel()
        m.start()
        _model = State(initialValue: m)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            // US-004: three stoplight dots. The green one pops once when everything turns green.
            Image(nsImage: StatusGlyph.image(for: model.presence, count: model.badgeCount, pop: model.bob, housing: model.prefs.housing))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
        .windowResizability(.contentMinSize)
    }
}
