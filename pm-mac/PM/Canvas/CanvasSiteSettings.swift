import Foundation

/// What a web card tells a site it is (backlog 31).
///
/// **Safari unless a site is told otherwise.** A card is Safari's engine at Safari's version, and saying
/// so is the honest default — see `CanvasWebSession.applicationName`. The other two are for the site
/// that turns Safari away regardless: a site that only tested in Chrome, or a web app with an
/// allow-list two browsers long. Claiming to be one of them changes what the site *sends*, not what
/// renders it, so a site that then uses something WebKit lacks will break in a new way; that is the
/// trade, and it is made one site at a time.
///
/// **The whole string, not a tail.** Safari's claim is appended to the user agent WebKit composes;
/// anybody else's has to replace it, because WebKit's own tokens are the ones that say Safari. So these
/// are the strings those browsers send on a Mac today, with the frozen parts frozen where they froze —
/// Chrome's `10_15_7` and its `.0.0.0`, Firefox's `10.15` — since those are what detection tables
/// expect to see.
enum CanvasBrowserIdentity: String, CaseIterable {
    case safari, chrome, firefox

    var title: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Chrome"
        case .firefox: return "Firefox"
        }
    }

    /// The user agent to put on a web view outright, or nil for Safari, which is WebKit's own string
    /// with `CanvasWebSession.applicationName` on the end.
    func userAgent(on date: Date = Date()) -> String? {
        switch self {
        case .safari:
            return nil
        case .chrome:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
                + "Chrome/\(Self.chromeVersion(on: date)).0.0.0 Safari/537.36"
        case .firefox:
            let version = Self.firefoxVersion(on: date)
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:\(version).0) Gecko/20100101 Firefox/\(version).0"
        }
    }

    /// **Counted from a known release rather than written down.** Both ship a major version every four
    /// weeks, so a constant would be old within a month and turned away by the same version checks this
    /// exists to pass. One behind the count, because the schedule slips a week now and then, and a version
    /// that hasn't shipped yet is a stranger claim than one a few weeks old.
    static func chromeVersion(on date: Date) -> Int {
        version(since: 140, released: (2025, 9, 2), on: date)
    }

    static func firefoxVersion(on date: Date) -> Int {
        version(since: 143, released: (2025, 9, 16), on: date)
    }

    private static func version(since known: Int, released: (Int, Int, Int), on date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let anchor = calendar.date(from: DateComponents(year: released.0, month: released.1, day: released.2))!
        let days = calendar.dateComponents([.day], from: anchor, to: date).day ?? 0
        return known + max(days / 28 - 1, 0)
    }
}

/// Everything PM remembers about one site rather than one card.
///
/// **Per site, because that is where compatibility breaks.** A site that turns a browser away turns away
/// every card showing it, on every board, and the sign-in window opened for one of them; blocking that
/// empties a page empties it everywhere. Autoplay, mute, page zoom and the session stay on the card,
/// because they are about what that card is for.
struct CanvasSite: Equatable {
    var identity: CanvasBrowserIdentity = .safari
    var blocksAds = true

    /// A site with nothing changed isn't stored, so the list in Settings is exactly the exceptions.
    var isDefault: Bool { self == CanvasSite() }
}

/// The per-site store — `CanvasSite` by `CanvasBlockPolicy.siteKey`, in user defaults.
///
/// **This is the place the ad-blocking exceptions already were**, widened: they used to be a list of
/// excused sites under `PMCanvasUnfilteredSites`, and are folded in the first time the store is read.
/// Whatever a site needs next — 26's keep-this-running, 43's freeze — is a field here rather than a
/// third list beside it.
enum CanvasSiteSettings {
    static let defaultsKey = "PMCanvasSites"
    static let legacyUnfilteredKey = "PMCanvasUnfilteredSites"
    /// Posted after any site changes, so the list in Settings can follow a change made from a card.
    static let changed = Notification.Name("PMCanvasSitesChanged")

    /// Every site with something changed, by key.
    static func all(in defaults: UserDefaults = .standard) -> [String: CanvasSite] {
        migrate(defaults)
        let stored = defaults.dictionary(forKey: defaultsKey) as? [String: [String: Any]] ?? [:]
        var sites: [String: CanvasSite] = [:]
        for (raw, fields) in stored {
            // Keyed on the way out as well as in, so a record written by hand — `www.Example.com` — means
            // what it plainly says.
            let key = CanvasBlockPolicy.siteKey(for: raw)
            let site = decode(fields)
            guard !key.isEmpty, !site.isDefault else { continue }
            sites[key] = site
        }
        return sites
    }

    static func site(for host: String?, in defaults: UserDefaults = .standard) -> CanvasSite {
        guard let host else { return CanvasSite() }
        let key = CanvasBlockPolicy.siteKey(for: host)
        guard !key.isEmpty else { return CanvasSite() }
        return all(in: defaults)[key] ?? CanvasSite()
    }

    /// Change one site. Returns the key it was stored under, or nil when the host has no site to speak of.
    @discardableResult
    static func update(_ host: String, in defaults: UserDefaults = .standard,
                       _ change: (inout CanvasSite) -> Void) -> String? {
        let key = CanvasBlockPolicy.siteKey(for: host)
        guard !key.isEmpty else { return nil }
        var sites = all(in: defaults)
        var site = sites[key] ?? CanvasSite()
        change(&site)
        sites[key] = site.isDefault ? nil : site
        save(sites, to: defaults)
        NotificationCenter.default.post(name: changed, object: nil)
        return key
    }

    /// The sites ad blocking is off for — what `CanvasBlockPolicy.filters` asks about.
    static func unblocked(in defaults: UserDefaults = .standard) -> Set<String> {
        Set(all(in: defaults).filter { !$0.value.blocksAds }.keys)
    }

    // MARK: Storage

    private static func decode(_ fields: [String: Any]) -> CanvasSite {
        var site = CanvasSite()
        if let raw = fields["identity"] as? String, let identity = CanvasBrowserIdentity(rawValue: raw) {
            site.identity = identity
        }
        if let blocks = fields["blocksAds"] as? Bool { site.blocksAds = blocks }
        return site
    }

    private static func encode(_ site: CanvasSite) -> [String: Any] {
        var fields: [String: Any] = [:]
        if site.identity != .safari { fields["identity"] = site.identity.rawValue }
        if !site.blocksAds { fields["blocksAds"] = false }
        return fields
    }

    private static func save(_ sites: [String: CanvasSite], to defaults: UserDefaults) {
        defaults.set(sites.mapValues(encode), forKey: defaultsKey)
    }

    /// Fold the old list of excused sites in, once, and drop it — so there is one answer to "is this site
    /// blocked" rather than two that could disagree.
    private static func migrate(_ defaults: UserDefaults) {
        guard let legacy = defaults.stringArray(forKey: legacyUnfilteredKey) else { return }
        var stored = defaults.dictionary(forKey: defaultsKey) as? [String: [String: Any]] ?? [:]
        for raw in legacy {
            let key = CanvasBlockPolicy.siteKey(for: raw)
            guard !key.isEmpty else { continue }
            stored[key, default: [:]]["blocksAds"] = false
        }
        defaults.set(stored, forKey: defaultsKey)
        defaults.removeObject(forKey: legacyUnfilteredKey)
    }
}
