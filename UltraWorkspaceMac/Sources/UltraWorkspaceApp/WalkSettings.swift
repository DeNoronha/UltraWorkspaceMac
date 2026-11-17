import SwiftUI
import UltraBarKit

/// Apps → Walk: the dog, how often and how long, the active hours, the rain, the calendars that say when you are busy,
/// and the walks logged so far.
struct WalkSettings: View {
    @ObservedObject var feed: WalkFeed
    @EnvironmentObject var settings: AppSettings
    @State private var calendars: [CalendarSource.CalInfo] = []

    var body: some View {
        Section {
            TextField("Dog's name", text: $settings.walkDog, prompt: Text("Name on the bar"))
            Picker("A walk every", selection: $settings.walkHours) {
                ForEach([2, 2.5, 3, 3.5, 4, 5, 6, 8], id: \.self) { h in Text(h == h.rounded() ? "\(Int(h)) hours" : String(format: "%.1f hours", h)).tag(h) }
            }
            Picker("A walk takes", selection: $settings.walkMinutes) {
                ForEach([15, 20, 30, 45, 60, 90], id: \.self) { Text("\($0) minutes").tag($0) }
            }
            HStack {
                Picker("Reminders from", selection: $settings.walkFrom) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                Picker("until", selection: $settings.walkTo) { ForEach(1...24, id: \.self) { Text(String(format: "%02d:00", $0 % 24)).tag($0) } }
            }
            Toggle("Show the rain (Open-Meteo, at your location)", isOn: $settings.walkWeather)
        } header: {
            Text("Walks")
        } footer: {
            Footnote("The first walk is due when the reminders start, the next one this long after the last walk ended. Outside these hours the bar stays quiet. The best moment is the first free gap in your calendars long enough for a walk, a dry one when the rain allows; during a meeting the bar waits until it is over. The rain is asked for at the location under Settings → Location & Units, rounded to about 100 m, every 15 minutes while Walk is on the bar.")
        }
        Section {
            if CalendarSource.authStatus() != .authorized {
                Text("Deckhand has no access to your calendars, so walks are not fitted around meetings. Allow it in System Settings → Privacy & Security → Calendars.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(calendars) { cal in
                    Toggle(isOn: Binding(
                        get: { settings.walkCalendars.isEmpty || settings.walkCalendars.contains(cal.id) },
                        set: { on in toggle(cal.id, on: on) })) {
                        HStack(spacing: 6) {
                            Circle().fill(Color(red: cal.rgb.0, green: cal.rgb.1, blue: cal.rgb.2)).frame(width: 9, height: 9)
                            Text(cal.title)
                            Text(cal.source).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Busy from these calendars")
        } footer: {
            Footnote("Only when you are busy is used, never what the meeting is: events marked free, declined, cancelled and all-day ones don't count.")
        }
        Section {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                VStack(alignment: .leading, spacing: 4) {
                    StatusLabel(feed.summary, .ok)
                    if let e = feed.lastError { StatusLabel(e, .failed) }
                }
            }
            HStack {
                if feed.log.walking != nil {
                    Button("Back Home") { feed.endWalk() }
                } else {
                    Button("Going Now") { feed.startWalk() }
                    Button("Walked Already") { feed.walkedAlready() }
                }
                Button("Undo") { feed.undo() }.disabled(feed.log.walking == nil && !(feed.lastWalk.map { Date().timeIntervalSince($0.end) < 3600 } ?? false))
            }
            ForEach(feed.log.walks.suffix(8).reversed(), id: \.start) { w in
                HStack {
                    Text(w.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                    Text(Walks.duration(w.end.timeIntervalSince(w.start))).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) { feed.remove(w) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove")
                }
            }
        } header: {
            Text("Log")
        } footer: {
            Footnote("On the bar: Going now when you leave, Back home when you are back, or Walked already afterwards. Undo calls off a walk going on or removes one logged in the past hour. The log stays on this Mac, 60 days.")
        }
        .onAppear { calendars = CalendarSource.calendars() }
    }

    /// Empty means all calendars; switching one off turns the list into "all the others".
    private func toggle(_ id: String, on: Bool) {
        var set = settings.walkCalendars.isEmpty ? Set(calendars.map(\.id)) : Set(settings.walkCalendars)
        if on { set.insert(id) } else { set.remove(id) }
        settings.walkCalendars = set.count == calendars.count ? [] : calendars.map(\.id).filter { set.contains($0) }
    }
}
