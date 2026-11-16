import SwiftUI

/// Apps → Traffic: how many minutes of traffic the app adds up.
struct TrafficSettings: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Section {
            Picker("Add up the last", selection: $settings.trafficWindow) {
                Text("Minute").tag(1)
                Text("10 minutes").tag(10)
                Text("Hour").tag(60)
            }
        } header: {
            Text("Traffic")
        } footer: {
            Footnote("Only while Traffic is on the bar's screen: the network counters every 5 seconds and macOS's own nettop every 10 seconds for the bytes per app and connection. No packets are captured and nothing needs administrator rights. Host names come from reverse DNS on this Mac; nothing else is looked up or sent anywhere.")
        }
    }
}
