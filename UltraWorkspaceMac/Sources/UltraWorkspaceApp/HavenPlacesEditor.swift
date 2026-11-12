import SwiftUI
import MapKit

/// Apps → Haven → Places: the places Haven watches, edited in Deckhand instead of in haven.json. Each place is
/// picked on a map (search or click) with a size for its berth area and its approach; the boxes in the file are
/// worked out from those. A place whose size and location are left alone keeps the boxes it had, so hand-tuned
/// places in the file survive an edit of their name or destination words.
struct HavenPlacesPanel: View {
    @State private var places: [HavenPlace] = HavenFeed.loadPlaces().places
    @State private var fromFile = HavenFeed.loadPlaces().fromFile
    @State private var editing: EditTarget?
    @State private var saveError: String?

    struct EditTarget: Identifiable { let id = UUID(); let index: Int?; let place: HavenPlace }

    var body: some View {
        Panel("Places", footer: "Up to six. A ship lying still in a place's area counts as alongside; a moving ship in its approach counts as on its way when it closes in or names one of the place's destination words. Sea ports count ships from a length you choose, terminals count barges. The list stays on this Mac; the bar follows a change within a few seconds. The map and the search use Apple Maps.") {
            if !fromFile { Text("Watching the port of Rotterdam until you change the list.").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(places.enumerated()), id: \.element.id) { i, p in
                HStack(spacing: 10) {
                    Image(systemName: p.kind == "port" ? "building.2" : "shippingbox").foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name)
                        Text(Self.summary(p)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { move(i, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(i == 0).help("Move left on the bar")
                    Button { move(i, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(i == places.count - 1).help("Move right on the bar")
                    Button("Edit…") { editing = EditTarget(index: i, place: p) }
                    Button { remove(i) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).disabled(places.count == 1).help("Remove this place")
                }
            }
            HStack {
                Button { editing = EditTarget(index: nil, place: HavenPlace(id: "", name: "", kind: "terminal", area: [], approach: nil)) } label: { Label("Add place", systemImage: "plus") }
                    .disabled(places.count >= 6)
                Button { NSWorkspace.shared.activateFileViewerSelecting([HavenFeed.ensurePlacesFile()]) } label: { Label(fromFile ? "Show haven.json" : "Create haven.json", systemImage: "doc.text") }
                    .buttonStyle(.borderless)
                if let saveError { Text(saveError).font(.caption).foregroundStyle(.orange) }
            }
        }
        .sheet(item: $editing) { t in
            HavenPlaceEditor(place: t.place, isNew: t.index == nil, takenIDs: Set(places.map(\.id)).subtracting([t.place.id])) { saved in
                var next = places
                if let i = t.index { next[i] = saved } else { next.append(saved) }
                save(next)
            }
        }
    }

    static func summary(_ p: HavenPlace) -> String {
        let c = p.center
        var parts = [p.kind == "port" ? "sea port · ships from \(p.minLength ?? 0) m" : "inland terminal",
                     String(format: "%.3f, %.3f", c.lat, c.lon)]
        if !p.match.isEmpty { parts.append(p.match.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func move(_ i: Int, _ d: Int) { var next = places; next.swapAt(i, i + d); save(next) }
    private func remove(_ i: Int) { var next = places; next.remove(at: i); save(next) }
    private func save(_ next: [HavenPlace]) {
        do { try HavenFeed.savePlaces(next); places = next; fromFile = true; saveError = nil }
        catch { saveError = "Could not save: \(error.localizedDescription)" }
    }
}

/// One place: name, kind, where (search or click on the map), how big, and the destination words.
private struct HavenPlaceEditor: View {
    let isNew: Bool
    let takenIDs: Set<String>
    let onSave: (HavenPlace) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var place: HavenPlace
    @State private var center: CLLocationCoordinate2D?
    @State private var areaKm: Double
    @State private var approachKm: Double
    @State private var words: String
    @State private var minLength: Int
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var searchNote: String?
    /// Bumped when the map should frame the place again (a new location), not on every slider step.
    @State private var frameToken = 0

    init(place: HavenPlace, isNew: Bool, takenIDs: Set<String>, onSave: @escaping (HavenPlace) -> Void) {
        self.isNew = isNew; self.takenIDs = takenIDs; self.onSave = onSave
        _place = State(initialValue: place)
        let valid = place.area.count == 4
        _center = State(initialValue: valid ? CLLocationCoordinate2D(latitude: place.center.lat, longitude: place.center.lon) : nil)
        _areaKm = State(initialValue: valid ? Geo.halfSizeKm(place.area, around: place.center) : (place.kind == "port" ? 8 : 1))
        _approachKm = State(initialValue: place.approach.map { Geo.reachKm($0, from: place.center) } ?? (place.kind == "port" ? 40 : 20))
        _words = State(initialValue: place.match.joined(separator: ", "))
        _minLength = State(initialValue: place.minLength ?? 200)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Add a place" : "Edit \(place.name)").font(.title3.bold())
            HStack(alignment: .top, spacing: 18) {
                form.frame(width: 300)
                VStack(alignment: .leading, spacing: 6) {
                    PlaceMap(area: place.area, approach: place.approach, frameToken: frameToken) { c in setCenter(c, reframe: false) }
                        .frame(width: 440, height: 340)
                        .overlay(alignment: .center) {
                            if center == nil { Text("Search for a place, or click on the map").padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)) }
                        }
                    HStack(spacing: 14) {
                        Label("area: alongside", systemImage: "square.fill").foregroundStyle(.green)
                        Label("approach: on its way", systemImage: "square").foregroundStyle(.cyan)
                    }.font(.caption)
                    Text("Click on the map to move the place there.").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { onSave(finished()); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(center == nil || place.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Find").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("A port, terminal or town", text: $query).onSubmit(search)
                    Button(action: search) { Image(systemName: "magnifyingglass") }.disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                }
                if let searchNote { Text(searchNote).font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(results.prefix(5).enumerated()), id: \.offset) { _, item in
                    Button { pick(item) } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.name ?? "Place").lineLimit(1)
                            Text(Self.address(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            Divider()
            TextField("Name on the bar", text: $place.name)
            Picker("Kind", selection: $place.kind) {
                Text("Inland terminal").tag("terminal")
                Text("Sea port").tag("port")
            }.pickerStyle(.segmented).labelsHidden()
            if place.kind == "port" {
                Stepper("Ships from \(minLength) m", value: $minLength, in: 50...400, step: 10)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Area: \(Self.km(areaKm)) around the place").font(.callout)
                Slider(value: Binding(get: { areaKm }, set: { areaKm = $0; reshape() }), in: 0.2...20)
                Text("Ships lying still in here count as alongside.").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Approach: \(Self.km(approachKm)) around the place").font(.callout)
                Slider(value: Binding(get: { approachKm }, set: { approachKm = max($0, areaKm); reshape() }), in: 2...100)
                Text("Moving ships in here that close in count as on their way.").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                TextField("Destination words, e.g. NIJMEGEN, NLNIJ", text: $words)
                Text("A moving ship whose AIS destination contains one of these is on its way, even before it closes in.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true; searchNote = nil
        let req = MKLocalSearch.Request(); req.naturalLanguageQuery = q
        if let c = center { req.region = MKCoordinateRegion(center: c, latitudinalMeters: 400_000, longitudinalMeters: 400_000) }
        Task { @MainActor in
            defer { searching = false }
            do { results = try await MKLocalSearch(request: req).start().mapItems; if results.isEmpty { searchNote = "Nothing found." } }
            catch { results = []; searchNote = "Nothing found." }
        }
    }

    private func pick(_ item: MKMapItem) {
        if place.name.trimmingCharacters(in: .whitespaces).isEmpty, let n = item.name { place.name = n }
        if words.trimmingCharacters(in: .whitespaces).isEmpty, let town = item.placemark.locality { words = town.uppercased() }
        results = []; query = ""
        setCenter(item.placemark.coordinate, reframe: true)
    }

    private func setCenter(_ c: CLLocationCoordinate2D, reframe: Bool) {
        center = c; reshape()
        if reframe { frameToken += 1 }
    }

    /// Boxes from the centre and the two sizes. Only called when the user moves the place or a slider.
    private func reshape() {
        guard let c = center else { return }
        place.area = Geo.box(c, km: areaKm)
        place.approach = Geo.box(c, km: max(approachKm, areaKm))
        if frameToken == 0 { frameToken = 1 }
    }

    private func finished() -> HavenPlace {
        var p = place
        p.name = p.name.trimmingCharacters(in: .whitespaces)
        if p.id.isEmpty { p.id = Self.uniqueID(p.name, taken: takenIDs) }
        p.match = words.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
        p.minLength = p.kind == "port" ? minLength : nil
        return p
    }

    static func uniqueID(_ name: String, taken: Set<String>) -> String {
        let base = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        let root = base.isEmpty ? "place" : base
        var id = root, n = 2
        while taken.contains(id) { id = "\(root)-\(n)"; n += 1 }
        return id
    }
    static func km(_ v: Double) -> String { v < 1 ? "\(Int((v * 1000 / 50).rounded() * 50)) m" : String(format: v < 10 ? "%.1f km" : "%.0f km", v) }
    static func address(_ item: MKMapItem) -> String {
        let p = item.placemark
        return [p.thoroughfare, p.locality, p.country].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Kilometres and boxes on the scale of a port: flat-earth is plenty.
private enum Geo {
    static let kmPerDegLat = 111.32
    static func kmPerDegLon(_ lat: Double) -> Double { kmPerDegLat * cos(lat * .pi / 180) }
    static func box(_ c: CLLocationCoordinate2D, km: Double) -> [Double] {
        let dLat = km / kmPerDegLat, dLon = km / kmPerDegLon(c.latitude)
        return [c.latitude - dLat, c.latitude + dLat, c.longitude - dLon, c.longitude + dLon].map { ($0 * 10_000).rounded() / 10_000 }
    }
    /// Half the larger side of a box, in km.
    static func halfSizeKm(_ b: [Double], around c: (lat: Double, lon: Double)) -> Double {
        guard b.count == 4 else { return 1 }
        return max((b[1] - b[0]) / 2 * kmPerDegLat, (b[3] - b[2]) / 2 * kmPerDegLon(c.lat))
    }
    /// How far a box reaches from the centre (its furthest side), in km.
    static func reachKm(_ b: [Double], from c: (lat: Double, lon: Double)) -> Double {
        guard b.count == 4 else { return 20 }
        return max(abs(b[0] - c.lat), abs(b[1] - c.lat)) * kmPerDegLat > max(abs(b[2] - c.lon), abs(b[3] - c.lon)) * kmPerDegLon(c.lat)
            ? max(abs(b[0] - c.lat), abs(b[1] - c.lat)) * kmPerDegLat
            : max(abs(b[2] - c.lon), abs(b[3] - c.lon)) * kmPerDegLon(c.lat)
    }
}

/// An Apple Maps view with the place's area (green) and approach (cyan); a click reports where.
private struct PlaceMap: NSViewRepresentable {
    let area: [Double]
    let approach: [Double]?
    let frameToken: Int
    let onClick: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = false
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        map.addGestureRecognizer(click)
        // Start on the Netherlands and its neighbours until there is a place to show.
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 52.0, longitude: 5.3), latitudinalMeters: 450_000, longitudinalMeters: 450_000), animated: false)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.onClick = onClick
        map.removeOverlays(map.overlays)
        let approachPoly = approach.flatMap { Self.polygon($0, title: "approach") }
        let areaPoly = Self.polygon(area, title: "area")
        if let approachPoly { map.addOverlay(approachPoly) }
        if let areaPoly { map.addOverlay(areaPoly) }
        if frameToken != context.coordinator.framed, let outer = approachPoly ?? areaPoly {
            context.coordinator.framed = frameToken
            map.setVisibleMapRect(outer.boundingMapRect, edgePadding: NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24), animated: context.coordinator.framed > 1)
        }
    }

    static func polygon(_ b: [Double], title: String) -> MKPolygon? {
        guard b.count == 4 else { return nil }
        var pts = [CLLocationCoordinate2D(latitude: b[0], longitude: b[2]), CLLocationCoordinate2D(latitude: b[0], longitude: b[3]),
                   CLLocationCoordinate2D(latitude: b[1], longitude: b[3]), CLLocationCoordinate2D(latitude: b[1], longitude: b[2])]
        let p = MKPolygon(coordinates: &pts, count: pts.count); p.title = title
        return p
    }

    @MainActor final class Coordinator: NSObject, MKMapViewDelegate {
        var onClick: ((CLLocationCoordinate2D) -> Void)?
        var framed = 0
        @objc func clicked(_ g: NSClickGestureRecognizer) {
            guard let map = g.view as? MKMapView else { return }
            onClick?(map.convert(g.location(in: map), toCoordinateFrom: map))
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let poly = overlay as? MKPolygon else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolygonRenderer(polygon: poly)
            if poly.title == "area" {
                r.fillColor = NSColor.systemGreen.withAlphaComponent(0.35); r.strokeColor = .systemGreen; r.lineWidth = 2
            } else {
                r.fillColor = NSColor.systemCyan.withAlphaComponent(0.08); r.strokeColor = .systemCyan; r.lineWidth = 1.5
            }
            return r
        }
    }
}
