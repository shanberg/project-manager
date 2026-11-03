import AppKit
import Observation
import PmLib

/// Today's aways nobody has answered, kept current for the surfaces that show them without being
/// asked: the menu bar's dot and the project window's titlebar chip (docs/away-time.md).
///
/// Worked out off the main thread — it reads the agent transcripts and every notes file's head — and
/// refreshed when attention lands somewhere (a gap has just become an away), when an answer is given,
/// and every few minutes for answers given elsewhere and for midnight, when today's become yesterday's.
@MainActor @Observable
final class AwayWatch {
    static let shared = AwayWatch()

    /// Oldest first.
    private(set) var aways: [AttentionAway] = []
    var newest: AttentionAway? { aways.last }

    /// Posted when `aways` changes, for AppKit code that isn't observing.
    static let didChange = Notification.Name("PMAwayWatchDidChange")

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let queue = DispatchQueue(label: "pm.aways", qos: .utility)
    @ObservationIgnored private var generation = 0

    private init() {
        NotificationCenter.default.addObserver(forName: AttentionKeeper.didBegin, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AwayWatch.shared.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { AwayWatch.shared.refresh() }
        }
    }

    func refresh() {
        generation += 1
        let mine = generation
        queue.async {
            let found = todaysAways()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let watch = AwayWatch.shared
                    guard mine == watch.generation, found != watch.aways else { return }
                    watch.aways = found
                    NotificationCenter.default.post(name: Self.didChange, object: watch)
                }
            }
        }
    }
}

/// The answers to an away, for every surface that offers them — one list, so the menu bar, the
/// titlebar chip and the Day card can't come to disagree about what can be said (docs/away-time.md).
///
/// In order: Count and Switch to the suggested project (where asked for, and only when it isn't where
/// you are already); Count for the suggestion, the interrupted project and the focused one, each once;
/// Count as a Sitting in the first of those; Other Project; Not Work.
@MainActor
enum AwayAnswers {
    struct Answer: Equatable {
        /// Nil is "not work".
        var project: String?
        var sitting = false
        /// Move focus there too: the time was that project's, and so is what comes next.
        var switching = false
    }

    /// A refused answer, in words. The menu has closed by then, so it can't say so itself.
    static var onFailure: (String) -> Void = { _ in }

    /// The projects offered by name, in order, each once.
    static func offered(for away: AttentionAway, focused: String?) -> [String] {
        var out: [String] = []
        for folder in [away.suggested, away.project, focused].compactMap({ $0 }) where !out.contains(folder) {
            out.append(folder)
        }
        return out
    }

    /// The project Count and Switch would move to, when there is one worth offering.
    static func switchTarget(for away: AttentionAway, focused: String?) -> String? {
        guard let suggested = away.suggested, suggested != focused else { return nil }
        return suggested
    }

    static func title(_ folder: String, limit: Int = 40) -> String {
        let title = PmLib.projectTitle(fromFolderName: folder)
        return title.count > limit ? String(title.prefix(limit - 1)) + "…" : title
    }

    /// "Away 12:05 – 12:35 PM".
    static func heading(_ away: AttentionAway) -> String {
        guard let from = away.fromDate, let to = away.toDate else { return "Away" }
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "Away \(formatter.string(from: from, to: to))"
    }

    /// "1h 30m · Maxwell Carmody? · was on Self" when the evidence suggests another project; else
    /// "1h 30m · Self".
    static func subtitle(_ away: AttentionAway) -> String {
        let length = durationLabel(away.seconds)
        let interrupted = PmLib.projectTitle(fromFolderName: away.project)
        guard let suggested = away.suggested, suggested != away.project else { return "\(length) · \(interrupted)" }
        return "\(length) · \(PmLib.projectTitle(fromFolderName: suggested))? · was on \(interrupted)"
    }

    /// One line per piece of evidence: "Calendar · Carmody review · 30m", "Claude Code · ~/dev/x · 58m".
    static func evidenceLines(_ away: AttentionAway) -> [String] {
        away.evidence.map { evidence in
            let what = evidence.isCalendar ? "Calendar · \(evidence.title ?? "")" : "Claude Code · \(evidence.folder ?? "")"
            return "\(what) · \(durationLabel(Double(evidence.minutes) * 60))"
        }
    }

    // MARK: AppKit

    /// The answers as menu items, appended to `menu`: the evidence first, as disabled lines.
    static func fill(_ menu: NSMenu, for away: AttentionAway, store: PMStore, switching: Bool) {
        for line in evidenceLines(away) {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if !away.evidence.isEmpty { menu.addItem(.separator()) }

        let focused = store.projectName
        if switching, let target = switchTarget(for: away, focused: focused) {
            menu.addItem(item("Count and Switch to \(title(target))", away, Answer(project: target, switching: true)))
            menu.addItem(.separator())
        }
        let offered = offered(for: away, focused: focused)
        for folder in offered {
            menu.addItem(item("Count for \(title(folder))", away, Answer(project: folder)))
        }
        if let first = offered.first {
            menu.addItem(item("Count as a Sitting in \(title(first, limit: 30))", away,
                              Answer(project: first, sitting: true)))
        }
        let others = store.recents.filter { !offered.contains($0.name) }
        if !others.isEmpty {
            let other = NSMenu(title: "Other Project")
            for recent in others { other.addItem(item(title(recent.name), away, Answer(project: recent.name))) }
            let row = NSMenuItem(title: "Other Project", action: nil, keyEquivalent: "")
            row.submenu = other
            menu.addItem(row)
        }
        menu.addItem(.separator())
        menu.addItem(item("Not Work", away, Answer(project: nil)))
    }

    /// The whole menu for one away, headed with its time and length — what the titlebar chip opens.
    static func menu(for away: AttentionAway, store: PMStore, switching: Bool) -> NSMenu {
        let menu = NSMenu(title: heading(away))
        let head = NSMenuItem(title: heading(away), action: nil, keyEquivalent: "")
        head.isEnabled = false
        if #available(macOS 14.4, *) { head.subtitle = subtitle(away) }
        menu.addItem(head)
        menu.addItem(.separator())
        fill(menu, for: away, store: store, switching: switching)
        return menu
    }

    private static func item(_ title: String, _ away: AttentionAway, _ answer: Answer) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(Target.answer(_:)), keyEquivalent: "")
        item.target = Target.shared
        item.representedObject = Picked(away: away, answer: answer)
        return item
    }

    private final class Picked: NSObject {
        let away: AttentionAway
        let answer: Answer
        init(away: AttentionAway, answer: Answer) {
            self.away = away
            self.answer = answer
        }
    }

    private final class Target: NSObject {
        static let shared = Target()
        @objc func answer(_ sender: NSMenuItem) {
            guard let picked = sender.representedObject as? Picked else { return }
            MainActor.assumeIsolated { AwayAnswers.give(picked.answer, to: picked.away) }
        }
    }

    // MARK: Answering

    /// Write the answer through `time.count`, and move focus when it was Count and Switch. No undo: the
    /// menus have none yet (docs/away-time.md); the Time and Day cards keep their own.
    static func give(_ answer: Answer, to away: AttentionAway) {
        var input = ApiInput()
        input.from = away.from
        input.to = away.to
        if let project = answer.project { input.project = project } else { input.notWork = true }
        if answer.sitting { input.sitting = true }
        do {
            _ = try PMContract.perform(.timeCount, input)
        } catch {
            let message = ApiError.from(error).message
            Log.write("away answer refused: \(message)")
            onFailure(message)
            return
        }
        if answer.switching, let project = answer.project {
            // The project's window, which is where focus lives while one is in front, and the focus.
            if let key = ProjectIndex.shared.projectKey(forFolder: project) {
                PMStore.setGlobalFocus(key: key) { (NSApp.delegate as? AppDelegate)?.syncFocusedStore() }
            }
            _ = WindowManager.shared.open(named: project)
        }
        AwayWatch.shared.refresh()
    }
}
