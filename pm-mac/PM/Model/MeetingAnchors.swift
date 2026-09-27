import Foundation
import PmLib

/// Finds the last meeting a since-the-last-meeting period counts from, from the project's calendars,
/// and keeps it where the period's range can read it (`CanvasMeetingAnchors`). On the main actor
/// because EventKit is asked there; cards call it as they look, which is often enough to follow the
/// calendar — a meeting that ends moves every card set to it on at its next look.
@MainActor
enum MeetingAnchors {
    /// How far back a last meeting is looked for. A project met less often than this has none.
    static let lookBack: TimeInterval = 120 * 86_400

    static func refresh(_ project: String, now: Date = Date()) {
        var meeting: CanvasMeetingAnchors.Meeting?
        if CalendarEvents.shared.access == .granted,
           let links = try? projectEventLinks(projects: [project]), !links.isEmpty {
            let events = CalendarEvents.shared.events(in: DateInterval(start: now.addingTimeInterval(-lookBack), end: now),
                                                      links: links)
            meeting = lastMeeting(events, now: now).map { .init(start: $0.start, title: meetingSittingLabel($0)) }
        }
        CanvasMeetingAnchors.set(meeting, for: project)
    }

    /// The projects a since-the-last-meeting period can name: every one whose calendars are linked.
    static func projects() -> [ProjectEventLink] {
        ((try? projectEventLinks()) ?? []).sorted { $0.projectName.localizedStandardCompare($1.projectName) == .orderedAscending }
    }
}
