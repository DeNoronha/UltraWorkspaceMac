import Foundation
import EventKit
import CoreGraphics

/// Calendar / upcoming-event source backed by EventKit.
///
/// Degrades gracefully when access has not been granted: `authStatus()` reports
/// the current permission, and `upcoming(_:)` returns `[]` whenever it is not
/// authorized or anything goes wrong. The app's Info.plist must carry an
/// `NSCalendarsUsageDescription` string (added by the integrator) for the
/// system access prompt to appear.
enum CalAuth: Sendable {
    case authorized
    case denied
    case notDetermined
}

/// A single upcoming calendar event, flattened into `Sendable` value types so it
/// can cross actor/task boundaries. `calendarColorRGBA` is the owning calendar's
/// color as a straight (r,g,b) tuple in 0...1.
struct CalEvent: Sendable {
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendarColorRGBA: (Double, Double, Double)
}

@MainActor
final class CalendarSource {

    /// Current EventKit authorization mapped to `CalAuth`.
    nonisolated static func authStatus() -> CalAuth {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess:
            return .authorized
        case .authorized:
            // Deprecated on macOS 14+ but still the value on older systems.
            return .authorized
        case .restricted, .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        case .writeOnly:
            // Write-only can't read events; treat as not usable for display.
            return .denied
        @unknown default:
            return .notDetermined
        }
    }

    /// Requests read access to events. Uses the macOS 14+ full-access API when
    /// available, otherwise falls back to the legacy request. Returns whether
    /// access was granted.
    static func requestAccess() async -> Bool {
        let store = EKEventStore()
        if #available(macOS 14.0, *) {
            do {
                return try await store.requestFullAccessToEvents()
            } catch {
                return false
            }
        } else {
            return await withCheckedContinuation { continuation in
                store.requestAccess(to: .event) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    struct CalInfo: Identifiable, Sendable { let id: String; let title: String; let source: String; let rgb: (Double, Double, Double) }

    /// All event calendars on this Mac (empty when not authorized).
    static func calendars() -> [CalInfo] {
        guard authStatus() == .authorized else { return [] }
        return EKEventStore().calendars(for: .event)
            .map { CalInfo(id: $0.calendarIdentifier, title: $0.title, source: $0.source?.title ?? "", rgb: rgb(from: $0.cgColor)) }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    /// Events from now through the next 24 hours, sorted by start, mapped to
    /// `CalEvent`. `calendarIDs` empty = all calendars. Returns `[]` if not authorized.
    ///
    /// The EventKit query (`events(matching:)`) walks the calendar database synchronously and took
    /// tens of milliseconds per call; the calendar feed asked every minute and the cube card on every
    /// render, all on the main actor. It now runs in a detached task with its own `EKEventStore`
    /// (EventKit objects are not thread-safe, so the store is created and dropped inside that task);
    /// only the flattened `Sendable` `[CalEvent]` crosses back.
    static func upcoming(limit: Int = 3, calendarIDs: [String] = [], days: Int = 1) async -> [CalEvent] {
        guard authStatus() == .authorized else { return [] }
        return await Task.detached(priority: .utility) { query(limit: limit, calendarIDs: calendarIDs, days: days) }.value
    }

    /// The query itself, callable from any thread (synchronous wrapper for callers that are already
    /// off the main actor). Checks authorization again so it degrades to `[]` on its own.
    nonisolated static func query(limit: Int = 3, calendarIDs: [String] = [], days: Int = 1) -> [CalEvent] {
        guard authStatus() == .authorized else { return [] }

        let store = EKEventStore()
        let now = Date()
        let end = days <= 1 ? now.addingTimeInterval(24 * 60 * 60)
            : Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: now)) ?? now

        let chosen = calendarIDs.isEmpty ? nil : store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        if let chosen, chosen.isEmpty { return [] }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: chosen)
        let events = store.events(matching: predicate)

        let mapped = events
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map { ev -> CalEvent in
                CalEvent(
                    title: ev.title ?? "(No title)",
                    start: ev.startDate ?? now,
                    end: ev.endDate ?? (ev.startDate ?? now),
                    isAllDay: ev.isAllDay,
                    calendarColorRGBA: rgb(from: ev.calendar?.cgColor)
                )
            }
        return Array(mapped)
    }

    /// Extracts a straight (r,g,b) tuple in 0...1 from a calendar's CGColor,
    /// converting through device RGB when needed. Falls back to a neutral blue.
    nonisolated private static func rgb(from cgColor: CGColor?) -> (Double, Double, Double) {
        guard let cgColor else { return (0.35, 0.60, 0.95) }

        if let comps = cgColor.components, cgColor.numberOfComponents >= 3 {
            return (Double(comps[0]), Double(comps[1]), Double(comps[2]))
        }

        // Grayscale or an unexpected model: convert to device RGB.
        let rgbSpace = CGColorSpaceCreateDeviceRGB()
        if let converted = cgColor.converted(to: rgbSpace, intent: .defaultIntent, options: nil),
           let comps = converted.components, converted.numberOfComponents >= 3 {
            return (Double(comps[0]), Double(comps[1]), Double(comps[2]))
        }
        return (0.35, 0.60, 0.95)
    }
}
