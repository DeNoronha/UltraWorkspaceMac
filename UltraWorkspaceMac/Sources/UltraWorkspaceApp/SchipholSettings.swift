import SwiftUI
import UltraBarKit

/// Apps → Schiphol: the live traffic's state, and the optional Schiphol Public Flight API credentials for the
/// timetable. The credentials are kept as user-only files (`Store` secrets), never in settings.json, and only sent
/// to Schiphol's own hosts (api.auth.schiphol.nl, api.schiphol.nl).
struct SchipholSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var id = Store.shared.loadSecret(name: SchipholFeed.secretID) ?? ""
    @State private var key = Store.shared.loadSecret(name: SchipholFeed.secretKey) ?? ""

    var body: some View {
        Panel("Runways and traffic", footer: "Aircraft positions from adsb.lol (open ADS-B data, ODbL, no key), around Schiphol within 20 NM: every 10 s while the page is open on the bar, every 30 s while the app is only installed, so the 15-minute counts are right when you open it. Flight numbers and towns for the recent movements come from adsbdb.com. Runways in use are worked out from where the aircraft fly: on the extended centre line, low and descending is landing; past the runway, climbing is taking off.") {
            TimelineView(.periodic(from: .now, by: 3)) { _ in
                let f = model.barPages.schiphol
                if let e = f.trafficError { Text(e).font(.caption).foregroundStyle(.orange) }
                else if f.lastFetch == .distantPast { Text("Starts while Schiphol is on the bar.").font(.caption).foregroundStyle(.secondary) }
                else { Text("Live · \(f.aircraftCount) aircraft around the field · \(Int(Date().timeIntervalSince(f.lastFetch))) s ago").font(.caption).foregroundStyle(.green) }
            }
        }
        Panel("Timetable (optional)", footer: "Register at developer.schiphol.nl for the Public Flight API (free), create an application and paste its Client ID and Client secret (an older app_id and app_key work too). They are kept in user-only files on this Mac and only sent to Schiphol. Without them the app shows the runways, the traffic and the recent landings and take-offs; with them, the next arrivals and departures, refreshed every 3 minutes while the page is open.") {
            HStack {
                TextField("Client ID (or app_id)", text: $id).frame(width: 320)
                    .onChange(of: id) { v in Store.shared.saveSecret(v.trimmingCharacters(in: .whitespacesAndNewlines), name: SchipholFeed.secretID); model.barPages.schiphol.credentialsDidChange() }
            }
            HStack {
                SecureField("Client secret (or app_key)", text: $key).frame(width: 320)
                    .onChange(of: key) { v in Store.shared.saveSecret(v.trimmingCharacters(in: .whitespacesAndNewlines), name: SchipholFeed.secretKey); model.barPages.schiphol.credentialsDidChange() }
                TimelineView(.periodic(from: .now, by: 3)) { _ in
                    let f = model.barPages.schiphol
                    if id.isEmpty || key.isEmpty { Text("No key: runways and traffic only.").font(.caption).foregroundStyle(.secondary) }
                    else if let e = f.boardError { Text(e).font(.caption).foregroundStyle(.orange) }
                    else if f.boardAt != .distantPast { Text("Timetable · \(f.arrivals.count + f.departures.count) flights").font(.caption).foregroundStyle(.green) }
                    else { Text("Saved. Fetched while Schiphol is on the bar.").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}
