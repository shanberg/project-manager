import AppKit
import Observation
import PmLib

/// What the browser's front tab says about where your attention is (docs/away-time.md, Browser signals).
///
/// Every half minute, while a browser is in front and someone is at the keys:
///
/// - **A site that isn't work** (`AttentionKeeper.notWorkSites`) ends the span, as a not-work app does —
///   silently, through the timekeeper.
/// - **Another project's link** (a page its `## Links` names, a Slack channel it links) in front for
///   five minutes while you're tracked elsewhere becomes a hint: the titlebar chip offers to switch.
///   The stretch is kept, in memory only, so the Time card can mark the span afterwards.
/// - **A Slack channel no project links**, in front for five minutes on two different days, becomes an
///   offer to link it.
///
/// **Only browsers already allowed.** The tab is read over Apple Events, and a browser nobody has
/// allowed yet would ask — so this asks the system first, without prompting, and skips any browser
/// that would. Go to Project is where that permission is given. The address is compared and dropped;
/// nothing about a page is written, except a channel's ID and minutes for the link offer.
@MainActor @Observable
final class BrowserWatch {
    static let shared = BrowserWatch()

    enum Hint: Equatable {
        /// `project`'s link has been in front since `since`, while you're tracked on another.
        case otherProject(project: String, label: String, since: Date)
        /// A Slack channel no project links, often enough to be worth linking.
        case linkChannel(channel: String, name: String, url: String)
    }

    /// What the chip offers now. Nil most of the time.
    private(set) var hint: Hint?

    /// A stretch another project's link was in front, for the Time card (`sighting(for:)`).
    struct Sighting: Equatable {
        let project: String
        let label: String
        let from: Date
        var to: Date
    }
    /// This run's sightings, oldest first. Gone on quit, by design: nothing about pages is written.
    private(set) var sightings: [Sighting] = []

    /// How long another project's link stays in front before it's mentioned.
    static let otherProjectAfter: TimeInterval = 5 * 60
    static let interval: TimeInterval = 30

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let queue = DispatchQueue(label: "pm.browserwatch", qos: .utility)
    @ObservationIgnored private var links: BrowserLinkIndex?
    @ObservationIgnored private var linksRead = Date.distantPast
    /// The other-project link in front now, and since when.
    @ObservationIgnored private var current: (project: String, label: String, since: Date)?
    /// When the front tab became a not-work site.
    @ObservationIgnored private var notWorkSince: Date?
    /// The stretch "Stay" was said about: no more hints until the tab changes.
    @ObservationIgnored private var stayed: String?
    /// The unlinked channel in front, and when it was last counted.
    @ObservationIgnored private var channel: (id: String, counted: Date)?
    @ObservationIgnored private var lastCheck = Date.distantPast

    private init() {}

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { BrowserWatch.shared.check() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { BrowserWatch.shared.check() }
        }
    }

    // MARK: Looking

    func check() {
        let now = Date()
        // Nobody at the keys: the timekeeper has it, and a tab left open over lunch says nothing.
        guard AttentionKeeper.systemIdleSeconds() < 120,
              let app = NSWorkspace.shared.frontmostApplication,
              let bundle = app.bundleIdentifier, bundle != Bundle.main.bundleIdentifier,
              BrowserTab.family(of: bundle) ?? app.bundleURL.flatMap(BrowserTab.family(ofAppAt:)) != nil else {
            settle(page: nil, now: now)
            return
        }
        queue.async {
            let allowed = Self.mayAutomate(bundle)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard allowed else { return BrowserWatch.shared.settle(page: nil, now: now) }
                    BrowserTab.read(from: app) { page in BrowserWatch.shared.settle(page: page, now: now) }
                }
            }
        }
    }

    /// Whether Folio may already send `bundle` Apple Events — asked without a prompt.
    nonisolated private static func mayAutomate(_ bundle: String) -> Bool {
        var target = AEAddressDesc()
        let id = Array(bundle.utf8)
        guard AECreateDesc(typeApplicationBundleID, id, id.count, &target) == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false) == noErr
    }

    private func settle(page: BrowserPage?, now: Date) {
        let elapsed = min(now.timeIntervalSince(lastCheck), Self.interval * 2)
        lastCheck = now
        let address = page?.url.absoluteString

        // A site that isn't work: the timekeeper ends the span from when it came to the front.
        if let address, NotWorkSites.matches(address, domains: AttentionKeeper.notWorkSites) {
            if notWorkSince == nil { notWorkSince = now }
        } else {
            notWorkSince = nil
        }
        AttentionKeeper.shared.notWorkSite(notWorkSince != nil, since: notWorkSince ?? now)

        let focused = PMFiles.focusedProjectKey().flatMap(PMFiles.projectName(fromKey:))
        let match = address.flatMap { linkIndex(now: now).match($0) }

        // Another project's link.
        if let match, match.project != focused, notWorkSince == nil {
            if current?.project != match.project || current?.label != match.label {
                current = (match.project, match.label, now)
                stayed = nil
            }
            record(match.project, label: match.label, now: now)
        } else {
            current = nil
            stayed = nil
        }

        // A channel nobody links.
        var offer: Hint?
        if match == nil, let page, let key = LinkKey(page.url.absoluteString), case .slackChannel(let id) = key {
            if channel?.id == id, elapsed > 0 {
                var seen = Self.sightingsStore
                seen.add(Int((elapsed / 60).rounded()), channel: id, day: CanvasDayCard.isoDay(now))
                Self.sightingsStore = seen
            }
            channel = (id, now)
            if Self.sightingsStore.isWorthLinking(id), !Self.ignoredChannels.contains(id) {
                let name = slackChannelName(fromTitle: page.title).map { "#\($0)" } ?? "this channel"
                offer = .linkChannel(channel: id, name: name, url: page.url.absoluteString)
            }
        } else {
            channel = nil
        }

        let next: Hint?
        if let current, now.timeIntervalSince(current.since) >= Self.otherProjectAfter,
           stayed != Self.stretchKey(current.project, current.label),
           let focused, !Self.isQuiet(focused: focused, project: current.project, label: current.label) {
            next = .otherProject(project: current.project, label: current.label, since: current.since)
        } else {
            next = offer
        }
        if next != hint { hint = next }
    }

    private func linkIndex(now: Date) -> BrowserLinkIndex {
        // Notes change while the app runs; the index's own cache makes a re-read cheap.
        if links == nil || now.timeIntervalSince(linksRead) > 120 {
            links = try? BrowserLinkIndex.load()
            linksRead = now
        }
        return links ?? BrowserLinkIndex(entries: [])
    }

    private func record(_ project: String, label: String, now: Date) {
        if var last = sightings.last, last.project == project, last.label == label,
           now.timeIntervalSince(last.to) <= Self.interval * 2 + 5 {
            last.to = now
            sightings[sightings.count - 1] = last
        } else {
            sightings.append(Sighting(project: project, label: label, from: now, to: now))
        }
        // A day's worth is all the Time card can use.
        sightings.removeAll { now.timeIntervalSince($0.to) > 36 * 3600 }
    }

    /// The other project whose link was in front for at least five minutes of `span`, when that span
    /// is counted to some other project — what the Time card marks.
    func sighting(for span: AttentionSpan) -> Sighting? {
        guard let start = span.startDate, let end = span.endDate else { return nil }
        return sightings.first { sighting in
            sighting.project != span.project
                && min(sighting.to, end).timeIntervalSince(max(sighting.from, start)) >= Self.otherProjectAfter
        }
    }

    // MARK: Answers

    /// The chip's menu for the current hint.
    func menu(store: PMStore) -> NSMenu? {
        guard let hint else { return nil }
        let menu = NSMenu()
        switch hint {
        case .otherProject(let project, let label, let since):
            let minutes = max(1, Int(Date().timeIntervalSince(since) / 60))
            heading(menu, "\(label) · \(minutes)m in front")
            menu.addItem(item("Switch to \(AwayAnswers.title(project))") {
                BrowserWatch.shared.switchTo(project, since: since)
            })
            let focused = store.projectName ?? "this project"
            menu.addItem(item("Stay on \(AwayAnswers.title(focused))") {
                BrowserWatch.shared.stay(project, label)
            })
            menu.addItem(.separator())
            menu.addItem(item("Don't Ask About This Link While on \(AwayAnswers.title(focused, limit: 24))") {
                BrowserWatch.shared.quiet(focused: focused, project: project, label: label)
            })
        case .linkChannel(let channel, let name, let url):
            heading(menu, "\(name) · no project")
            if let focused = store.projectName {
                menu.addItem(item("Link \(name) to \(AwayAnswers.title(focused))") {
                    BrowserWatch.shared.link(url, name: name, to: focused)
                })
            }
            let others = store.recents.filter { $0.name != store.projectName }
            if !others.isEmpty {
                let other = NSMenu()
                for recent in others {
                    other.addItem(item(AwayAnswers.title(recent.name)) {
                        BrowserWatch.shared.link(url, name: name, to: recent.name)
                    })
                }
                let row = NSMenuItem(title: "Link to Other Project", action: nil, keyEquivalent: "")
                row.submenu = other
                menu.addItem(row)
            }
            menu.addItem(.separator())
            menu.addItem(item("Not a Project Channel") { BrowserWatch.shared.ignore(channel) })
        }
        return menu
    }

    /// Count the stretch since the tab came to the front for `project`, and move there.
    private func switchTo(_ project: String, since: Date) {
        var input = ApiInput()
        input.from = DoneLog.timestamp(since)
        input.to = DoneLog.timestamp(Date())
        input.project = project
        do {
            _ = try PMContract.perform(.timeCount, input)
        } catch {
            AwayAnswers.onFailure(ApiError.from(error).message)
        }
        if let key = ProjectIndex.shared.projectKey(forFolder: project) {
            PMStore.setGlobalFocus(key: key) { (NSApp.delegate as? AppDelegate)?.syncFocusedStore() }
        }
        _ = WindowManager.shared.open(named: project)
        current = nil
        hint = nil
    }

    private func stay(_ project: String, _ label: String) {
        stayed = Self.stretchKey(project, label)
        hint = nil
    }

    private func quiet(focused: String, project: String, label: String) {
        Self.quietPairs.append(Self.quietKey(focused: focused, project: project, label: label))
        hint = nil
    }

    private func link(_ url: String, name: String, to project: String) {
        var input = ApiInput()
        input.project = project
        input.text = url
        input.label = name
        do {
            _ = try PMContract.perform(.notesAddLink, input)
        } catch {
            AwayAnswers.onFailure(ApiError.from(error).message)
        }
        links = nil
        hint = nil
    }

    private func ignore(_ channel: String) {
        Self.ignoredChannels.append(channel)
        hint = nil
    }

    private func heading(_ menu: NSMenu, _ title: String) {
        let head = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())
    }

    private func item(_ title: String, _ act: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(Action.run(_:)), keyEquivalent: "")
        item.target = Action.shared
        item.representedObject = Action.Run(act)
        return item
    }

    private final class Action: NSObject {
        static let shared = Action()
        final class Run: NSObject {
            let act: @MainActor () -> Void
            init(_ act: @escaping @MainActor () -> Void) { self.act = act }
        }
        @objc func run(_ sender: NSMenuItem) {
            guard let run = sender.representedObject as? Run else { return }
            MainActor.assumeIsolated { run.act() }
        }
    }

    // MARK: Kept on this Mac

    private static func stretchKey(_ project: String, _ label: String) -> String { "\(project)\u{1F}\(label)" }
    private static func quietKey(focused: String, project: String, label: String) -> String {
        "\(focused)\u{1F}\(project)\u{1F}\(label)"
    }

    /// "Don't ask about this link while on …", as focused · project · link.
    private static var quietPairs: [String] {
        get { UserDefaults.standard.stringArray(forKey: "PMBrowserQuietLinks") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "PMBrowserQuietLinks") }
    }

    private static func isQuiet(focused: String, project: String, label: String) -> Bool {
        quietPairs.contains(quietKey(focused: focused, project: project, label: label))
    }

    /// Channels said not to be a project's.
    private static var ignoredChannels: [String] {
        get { UserDefaults.standard.stringArray(forKey: "PMSlackIgnoredChannels") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "PMSlackIgnoredChannels") }
    }

    private static var sightingsStore: ChannelSightings {
        get {
            UserDefaults.standard.data(forKey: "PMSlackChannelSightings")
                .flatMap { try? JSONDecoder().decode(ChannelSightings.self, from: $0) } ?? ChannelSightings()
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "PMSlackChannelSightings") }
    }
}
