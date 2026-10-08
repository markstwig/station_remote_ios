import SwiftUI

@main
struct StationApp: App {
    @State private var station = Station()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            TabView {
                HomeView().tabItem { Label("Playing", systemImage: "play.circle.fill") }
                CommandsView().tabItem { Label("Commands", systemImage: "magnifyingglass") }
                LogView().tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
                SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }
            }
            .environment(station)
            .preferredColorScheme(.dark)
            .task { station.connect() }
            .task { await station.monitor() }
            .onChange(of: phase) { _, new in
                guard new == .active else { return }
                station.nowPlaying.claim()
                if !station.online { station.connect() }
                Task { await station.refreshReachability() }
            }
        }
    }
}
