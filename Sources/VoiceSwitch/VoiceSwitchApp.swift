import SwiftUI

@main
struct VoiceSwitchApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            ContentView(state: state)
        } label: {
            MenuBarStatusIcon(model: state.hudModel)
        }
        .menuBarExtraStyle(.window)
    }
}
