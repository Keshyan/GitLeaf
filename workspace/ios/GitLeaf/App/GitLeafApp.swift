import SwiftUI

@main
struct GitLeafApp: App {
    @StateObject private var vm = GitLeafViewModel()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(vm)
                .preferredColorScheme(.dark)
                .tint(Color(red: 0.0, green: 0.88, blue: 0.62))
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject var vm: GitLeafViewModel

    var body: some View {
        TabView {
            CockpitView()
                .tabItem { Label("Cockpit", systemImage: "gauge.with.dots.needle.67percent") }

            BatteryLabView()
                .tabItem { Label("Battery Lab", systemImage: "battery.100percent.bolt") }

            TripEnergyView()
                .tabItem { Label("Trip", systemImage: "map.fill") }

            DiagnosticsServiceView()
                .tabItem { Label("Diagnostics", systemImage: "wrench.and.screwdriver.fill") }

            AdapterGarageView()
                .tabItem { Label("Adapter", systemImage: "antenna.radiowaves.left.and.right") }
        }
    }
}
