import SwiftUI

@main
struct TonebarApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            Image(systemName: model.isEnabled ? "slider.vertical.3" : "slider.horizontal.below.rectangle")
                .accessibilityLabel(model.isEnabled ? "Tonebar, equalizer on" : "Tonebar, equalizer off")
        }
        .menuBarExtraStyle(.window)
    }
}
