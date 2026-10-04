import SwiftUI

@main
struct StationApp: App {
    @State private var station = Station()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            TabView {
                ControlsView().tabItem { Label("Controls", systemImage: "play.circle.fill") }
                SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }
            }
            .environment(station)
            .preferredColorScheme(.dark)
            .task { station.connect() }
            .onChange(of: phase) { _, new in if new == .active && !station.online { station.connect() } }
        }
    }
}
