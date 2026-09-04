import SwiftUI
import StoplightCore

@main
struct StoplightApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
                .task { model.start() }
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
