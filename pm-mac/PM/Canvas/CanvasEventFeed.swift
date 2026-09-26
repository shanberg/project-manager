import Foundation
import PmLib

/// The calendar events a view card draws beside its answer (docs/views.md, Calendars C3–C4): those of
/// the projects the card already covers, over the span it draws, and nothing else.
///
/// **Read live, kept only while drawn.** Which projects show events is their frontmatter (`pm-events`,
/// read off the main thread and cached by PmLib against each file's date); the events themselves are
/// EventKit's, asked again whenever the card looks and whenever any calendar changes.
@MainActor
@Observable
final class CanvasEventFeed {
    private(set) var events: [ProjectEvent] = []

    /// Told when the events change, for a node view that redraws on its model's word.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var asked: (projects: [String]?, interval: DateInterval)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private let queue = DispatchQueue(label: "com.stuarthanberg.pm.viewevents", qos: .utility)

    init() {}

    /// Events already in hand, which never looks: for drawing a card in a test.
    init(showing events: [ProjectEvent]) {
        self.events = events
    }

    /// Follow changes to any calendar, in Folio or anywhere else, until `stop`.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: CalendarEvents.didChange, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Look for these projects' events over `interval`: nil projects is every project, and none is none.
    /// Nil `interval` is a card that draws no events, which then has none.
    func load(projects: [String]?, interval: DateInterval?) {
        asked = interval.map { (projects, $0) }
        refresh()
    }

    private func refresh() {
        generation += 1
        let mine = generation
        guard let (projects, interval) = asked, projects?.isEmpty != true,
              CalendarEvents.shared.access == .granted else { return show([]) }
        queue.async { [weak self] in
            let links = (try? projectEventLinks(projects: projects)) ?? []
            Task { @MainActor in
                guard let self, mine == self.generation else { return }
                self.show(links.isEmpty ? [] : CalendarEvents.shared.events(in: interval, links: links))
            }
        }
    }

    private func show(_ found: [ProjectEvent]) {
        guard found != events else { return }
        events = found
        onChange?()
    }
}
