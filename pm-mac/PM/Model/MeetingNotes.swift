import AppKit
import PmLib

/// Take Notes for This Meeting (views.md, Calendars step 4): the meeting on now, or about to be, in any
/// project that shows events — a sitting in that project named after it, opened to write in.
///
/// The one step 4 feature that names a sitting after an event, and it does so because it was asked:
/// a sitting that took a meeting's name on its own would be a name nobody chose, and only on the
/// sittings the app happened to start.
@MainActor
enum MeetingNotes {
    /// Asked for by menus as they open, so looked up at most this often.
    private static let freshness: TimeInterval = 5
    private static var memo: (at: Date, meeting: ProjectEvent?)?

    /// The meeting to take notes for, or nil: no calendar access, no project that shows events, or
    /// nothing on now or within ten minutes (`meetingForNotes`).
    static func current(now: Date = Date()) -> ProjectEvent? {
        if let memo, now.timeIntervalSince(memo.at) < freshness, now >= memo.at { return memo.meeting }
        var meeting: ProjectEvent?
        if CalendarEvents.shared.access == .granted, let links = try? projectEventLinks(), !links.isEmpty {
            // Back far enough to catch a long meeting already under way.
            let window = DateInterval(start: now.addingTimeInterval(-12 * 3600), end: now.addingTimeInterval(15 * 60))
            meeting = meetingForNotes(CalendarEvents.shared.events(in: window, links: links), now: now)
        }
        memo = (now, meeting)
        return meeting
    }

    /// The command's name, saying which meeting when there is one.
    static func title(for meeting: ProjectEvent?) -> String {
        meeting.map { "Take Notes for “\(meetingSittingLabel($0))”" } ?? PMCommand.takeMeetingNotes.title
    }

    /// Start or rejoin the meeting's sitting in its project, then open its note in that project's window.
    static func take(_ meeting: ProjectEvent) {
        guard let key = ProjectIndex.shared.projectKey(forFolder: meeting.projectFolder) else {
            NSSound.beep()
            return
        }
        let name = meetingSittingLabel(meeting)
        // The window first, so its board is up by the time the sitting is there to open in it.
        let window = WindowManager.shared.open(projectKey: key)
        let store = StoreRegistry.shared.acquire(key)
        store.reload {
            store.openSession(named: name) { _ in
                // The sitting is the current one now, so New Session opens it rather than making another.
                window.newSession(nil)
                StoreRegistry.shared.release(key)
                Log.write("meeting notes: \(meeting.projectFolder) -> \(name)")
            }
        }
        memo = nil
    }

    /// Take notes for the current meeting, or beep when there isn't one.
    static func takeCurrent() {
        guard let meeting = current() else { return NSSound.beep() }
        take(meeting)
    }
}
