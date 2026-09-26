import AppKit
import EventKit
import PmLib

/// The calendars on this Mac, read through EventKit (views.md, Calendars C1).
///
/// App-only on purpose: a CLI asking for calendar access is its own problem, so `pm`, Raycast and the
/// contract get no events. Events are read live, never written and never kept. What a project shows is
/// decided by its `pm-events` frontmatter, matched in PmLib (`ProjectEventSource`).
@MainActor
final class CalendarEvents {
    static let shared = CalendarEvents()

    /// Posted by EventKit when any calendar changes, in Folio or anywhere else.
    static let didChange = Notification.Name.EKEventStoreChanged

    let store = EKEventStore()

    enum Access { case notAsked, granted, denied }

    var access: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notAsked
        // Write-only can't read, which is all this does.
        default: .denied
        }
    }

    /// The system prompt, once. Afterwards the answer lives in System Settings, and this returns it.
    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    static func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        else { return }
        NSWorkspace.shared.open(url)
    }

    struct Calendar: Hashable, Identifiable {
        /// `calendarIdentifier`: fine for this Mac, this session; never written down (C2).
        let id: String
        let title: String
        /// The EventKit source's title: "iCloud", "Google", an address.
        let account: String
        let color: NSColor
    }

    struct Event: Hashable, Identifiable {
        /// Recurring events share an identifier, so a start makes an occurrence unique.
        var id: String { "\(eventID)@\(start.timeIntervalSinceReferenceDate)" }
        let eventID: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let calendar: String
        let account: String
    }

    /// Every calendar holding events, by account and then title. Empty without access.
    func calendars() -> [Calendar] {
        guard access == .granted else { return [] }
        return store.calendars(for: .event)
            .map { Calendar(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "",
                            color: $0.color ?? .systemGray) }
            .sorted {
                let byAccount = $0.account.localizedStandardCompare($1.account)
                return byAccount == .orderedSame
                    ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                    : byAccount == .orderedAscending
            }
    }

    /// The events in `interval` that belong to a project with these sources, by start. Only the
    /// calendars the sources name are searched.
    func events(in interval: DateInterval, for sources: [ProjectEventSource]) -> [Event] {
        guard access == .granted, !sources.isEmpty else { return [] }
        let calendars = store.calendars(for: .event).filter { calendar in
            sources.contains { $0.namesCalendar(calendar) }
        }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: calendars)
        return store.events(matching: predicate)
            .filter { sources.matches(calendar: $0.calendar.title, account: $0.calendar.source?.title, title: $0.title ?? "") }
            .map { event in
                Event(eventID: event.eventIdentifier ?? "", title: event.title ?? "", start: event.startDate,
                      end: event.endDate, isAllDay: event.isAllDay, calendar: event.calendar.title,
                      account: event.calendar.source?.title ?? "")
            }
            .sorted { $0.start < $1.start }
    }
}

private extension ProjectEventSource {
    /// Whether this source names `calendar` at all, whatever its `match` — which calendars to search.
    func namesCalendar(_ calendar: EKCalendar) -> Bool {
        ProjectEventSource(calendar: self.calendar, account: account)
            .matches(calendar: calendar.title, account: calendar.source?.title, title: "")
    }
}
