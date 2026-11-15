import SwiftUI
import UltraBarKit

/// Apps → Schiphol: the live traffic's state, and the optional Schiphol Public Flight API credentials for the
/// timetable. The credentials are kept in the secret store (Keychain `api:schiphol-id`, `api:schiphol-secret`), never in settings.json, and only sent
/// to Schiphol's own hosts (api.auth.schiphol.nl, api.schiphol.nl).
struct SchipholSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var id = Store.shared.loadSecret(name: SchipholFeed.secretID) ?? ""
    @State private var key = Store.shared.loadSecret(name: SchipholFeed.secretKey) ?? ""

    var body: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 3)) { _ in
                let f = model.barPages.schiphol
                if let e = f.trafficError { StatusLabel(e, .failed) }
                else if f.lastFetch == .distantPast { StatusLabel("Starts while Schiphol is on the bar.", .info) }
                else { StatusLabel("Live · \(f.aircraftCount) aircraft around the field · \(Int(Date().timeIntervalSince(f.lastFetch))) s ago", .ok) }
            }
            DetailsDisclosure(text: "Aircraft positions from adsb.lol (open ADS-B data, no key), within 20 NM of Schiphol: every 10 s while the page is open on the bar, every 30 s while the app is only installed. Flight numbers and towns come from adsbdb.com. Runways in use are worked out from where the aircraft fly: low and descending on the extended centre line is landing; climbing past the runway is taking off.")
        } header: {
            Text("Runways and traffic")
        } footer: {
            Footnote("Works without a key.")
        }
        Section {
            TextField("Client ID", text: $id, prompt: Text("Client ID or app_id"))
                .onChange(of: id) { v in Store.shared.saveSecret(v.trimmingCharacters(in: .whitespacesAndNewlines), name: SchipholFeed.secretID, debounce: true); model.barPages.schiphol.credentialsDidChange() }
            SecureField("Client secret", text: $key, prompt: Text("Client secret or app_key"))
                .onChange(of: key) { v in Store.shared.saveSecret(v.trimmingCharacters(in: .whitespacesAndNewlines), name: SchipholFeed.secretKey, debounce: true); model.barPages.schiphol.credentialsDidChange() }
            TimelineView(.periodic(from: .now, by: 3)) { _ in
                let f = model.barPages.schiphol
                if id.isEmpty || key.isEmpty { StatusLabel("No key: runways and traffic only.", .info) }
                else if let e = f.boardError { StatusLabel(e, .failed) }
                else if f.boardAt != .distantPast { StatusLabel("Timetable · \(f.arrivals.count + f.departures.count) flights", .ok) }
                else { StatusLabel("Saved. Fetched while Schiphol is on the bar.", .info) }
            }
            Link("Get a Key at developer.schiphol.nl", destination: URL(string: "https://developer.schiphol.nl")!)
        } header: {
            Text("Timetable (optional)")
        } footer: {
            Footnote("A free Public Flight API application. Kept in this Mac's Keychain and sent only to Schiphol.")
        }
    }
}
