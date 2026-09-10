import AppKit
import WebKit

/// The one browser session every web card shares, and the only way to end it.
///
/// **One store, not one per card.** Signing in is something you do to a *site*, not to a rectangle on
/// a board: duplicate a signed-in card, paste the same Jira URL onto a different board, or build a
/// fresh dashboard next month, and every one of those cards is already signed in because they are all
/// reading the same jar. Per-card isolation would be a defensible security posture in the abstract and
/// a useless dashboard in practice — twelve cards would mean twelve sign-ins, and a duplicate would
/// mean a thirteenth.
///
/// **Named, not the app's default.** The default store is the app-wide one, which `URLSession.shared`
/// also reads — that is how an icon fetch came to be capable of carrying a Jira session cookie. A
/// store with an identifier of its own is a container nothing else in PM can reach into by accident,
/// and, just as importantly, one that can be deleted outright in a single call.
///
/// What this is *not* is encryption. The data is still an ordinary file readable by anything running
/// as you; macOS offers no encrypted-at-rest option for WebKit storage. This buys separation and
/// revocability. FileVault is the answer to the file, and it isn't PM's to give.
@MainActor
enum CanvasWebSession {
    private static let identifierKey = "PMCanvasWebSessionID"
    private static let migratedKey = "PMCanvasWebSessionMigrated"

    /// The store every card and every sign-in window is built on.
    static let store: WKWebsiteDataStore = {
        let defaults = UserDefaults.standard
        let id: UUID
        if let saved = defaults.string(forKey: identifierKey), let existing = UUID(uuidString: saved) {
            id = existing
        } else {
            id = UUID()
            defaults.set(id.uuidString, forKey: identifierKey)
        }
        return WKWebsiteDataStore(forIdentifier: id)
    }()

    /// Carry sessions over from the store cards used to be built on, once.
    ///
    /// Without this, moving to a named store means every site you were signed in to forgets you — the
    /// exact experience this whole area exists to avoid.
    ///
    /// Cookies go through their own door. `fetchData(of:)` looks like the API for this and refuses the
    /// one type that constitutes being signed in — it answers "does not support fetching:
    /// WKWebsiteDataTypeCookies" — so the cookie store is copied jar to jar and everything else,
    /// including the local storage a modern login also keeps a token in, goes as a lump beside it.
    ///
    /// Best effort in every direction: the old store is left untouched, so the worst case is one
    /// sign-in rather than anything to repair.
    static func migrateOldSessions() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return }

        let old = WKWebsiteDataStore.default()
        let cookies = await old.httpCookieStore.allCookies()
        for cookie in cookies { await store.httpCookieStore.setCookie(cookie) }

        // One type at a time, because `fetchData(of:)` refuses most of them and refuses the *whole*
        // request when any one refused type is included. Probed against the macOS 26.5 SDK: of the 14
        // types `allWebsiteDataTypes()` returns, it accepts exactly one — local storage — and refuses
        // the other thirteen, cookies among them. Local storage happens to be the one worth having,
        // since that is where a token-based login keeps its token. Asking per type carries what can be
        // carried instead of losing the lot to whichever refusal comes first, and needs no hardcoded
        // list to go stale when the accepted set changes.
        var carried: [String] = []
        for type in WKWebsiteDataStore.allWebsiteDataTypes() where type != WKWebsiteDataTypeCookies {
            do {
                try await store.restoreData(try await old.fetchData(of: [type]))
                carried.append(type)
            } catch {
                continue
            }
        }
        defaults.set(true, forKey: migratedKey)
        Log.write("canvas web session: carried over \(cookies.count) cookie(s) "
            + "and \(carried.count) of \(WKWebsiteDataStore.allWebsiteDataTypes().count - 1) storage types")
    }

    // MARK: Profiles

    /// The jar a card drinks from, by name.
    ///
    /// **The shared session is still the default and still the right one.** Signing in is something you
    /// do to a site, and twelve cards on one tracker should mean one sign-in — that argument is above
    /// and none of it has changed. What it does not survive is the second account: work and personal
    /// mail, two tenants of the same tool, a client's staging box beside your own. Those are not one
    /// person's session, and no amount of sharing makes them one.
    ///
    /// So a card may name a profile, and a named profile is its own persistent store: its own cookies,
    /// its own local storage, its own idea of who you are. `nil` is the shared jar every card has always
    /// used. `ephemeralName` is the one reserved name — a store that is never written to disk and is
    /// gone when PM quits.
    ///
    /// Identifiers are kept rather than derived from the name, because a `WKWebsiteDataStore` is found
    /// by UUID and a name is something you can rename. Renaming is out of scope and would be, at worst,
    /// a new empty jar; losing the map would be every named profile signed out at once, which is why the
    /// map is written before the store is ever used.
    static let ephemeralName = "Private"

    static func store(named name: String?) -> WKWebsiteDataStore {
        guard let name, !name.isEmpty else { return store }
        guard name != ephemeralName else { return ephemeral }
        if let existing = profiles[name] { return existing }
        let made = WKWebsiteDataStore(forIdentifier: identifier(for: name))
        profiles[name] = made
        return made
    }

    /// One ephemeral store for every private card, made once per launch.
    ///
    /// Per card would be the stricter reading and the wrong one: two private cards on one board are
    /// nearly always two views of the same signed-out session, and making each its own would mean
    /// signing in twice to look at one site twice. A profile is a jar; this one is a jar with a hole in
    /// the bottom.
    private static let ephemeral = WKWebsiteDataStore.nonPersistent()

    /// The persistent stores this launch has handed out, so a name is one store rather than one per ask.
    /// A second `WKWebsiteDataStore(forIdentifier:)` on the same UUID is a second object over the same
    /// files, which is how a cookie written by one card fails to be seen by the next.
    private static var profiles: [String: WKWebsiteDataStore] = [:]

    /// Every named profile in use, for the menu that offers them.
    static var profileNames: [String] {
        let named = (UserDefaults.standard.dictionary(forKey: profilesKey) as? [String: String] ?? [:])
        return named.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static let profilesKey = "PMCanvasWebProfiles"

    private static func identifier(for name: String) -> UUID {
        var map = UserDefaults.standard.dictionary(forKey: profilesKey) as? [String: String] ?? [:]
        if let saved = map[name], let existing = UUID(uuidString: saved) { return existing }
        let made = UUID()
        map[name] = made.uuidString
        UserDefaults.standard.set(map, forKey: profilesKey)
        return made
    }

    // MARK: What a card calls itself

    /// The tail of the user agent every web card sends: `Version/<n> Safari/605.1.15`.
    ///
    /// **Not a spoof — a card *is* Safari.** Same WebKit, same version, same rendering. What it was
    /// missing was a name: a bare `WKWebView` sends a user agent that stops after
    /// `AppleWebKit/605.1.15 (KHTML, like Gecko)`, with no `Version/` and no `Safari/` token after it.
    /// Every browser-detection table in the world is a list of exactly those two tokens, so a card
    /// wasn't read as an old browser, it was read as an unknown one — which is the branch Slack and
    /// Google Docs send to their "your browser is not supported" page.
    ///
    /// **The version is the installed Safari's, read once.** A constant would be a lie the day after
    /// the next OS update, and the number is only meaningful because it tracks the engine actually
    /// doing the rendering. `Info.plist` is where Safari keeps it and the read costs one stat at first
    /// use. The fallback covers a machine where Safari has been moved or removed, and errs new: a
    /// version claimed too low is turned away by the same tables this exists to satisfy.
    static let applicationName: String = {
        let installed = Bundle(path: "/Applications/Safari.app")?
            .infoDictionary?["CFBundleShortVersionString"] as? String
        return "Version/\(installed ?? "26.0") Safari/605.1.15"
    }()

    /// Say so on a configuration, wherever one is built — a card, a card on a profile of its own, or a
    /// sign-in window. One call rather than a line each, because a sign-in window that identified
    /// itself differently from the card it was opened for would be signing in as a different browser.
    static func identify(_ configuration: WKWebViewConfiguration) {
        configuration.applicationNameForUserAgent = applicationName
    }

    /// Let Safari's Web Inspector attach to a card, a sign-in window or a popup — on the same switch
    /// the log uses.
    ///
    /// **Because the alternative is guessing.** A card is a real browser showing a real site, so the
    /// things that go wrong in one are the things that go wrong in any browser: a request that was
    /// refused, a cookie that wasn't sent, a script that threw on line four hundred. Every one of
    /// those is a minute's work with an inspector attached and unfalsifiable speculation without one,
    /// and until now PM offered no way to look — `isInspectable` has defaulted to false since macOS
    /// 13.3, so a notarised build was opaque even to the person who wrote it.
    ///
    /// **On `Log.isEnabled`, not a switch of its own.** It is the same question — "I am chasing
    /// something, tell me what you know" — and answering it in two places would mean a copy of PM that
    /// writes a log and refuses an inspector. It is off in a release build for the reason the log is:
    /// an inspectable web view is one any process running as you can attach to and drive, which is a
    /// door worth keeping shut on a card that is signed in to your mail. Debug builds get it outright.
    ///
    /// Turn it on for an installed copy the same way — `defaults write com.stuarthanberg.pm
    /// PMLogEnabled -bool YES` — then relaunch and look under Safari's Develop menu.
    static func allowInspecting(_ web: WKWebView) {
        web.isInspectable = Log.isEnabled
    }

    /// Everything one site has stored — its cookies, and the local storage a modern login also uses.
    ///
    /// Matched on the registrable domain, which is what WebKit files a record under: signing out of
    /// `jira.example.com` signs you out of `example.com`, because that is where the session cookie
    /// lives and pretending otherwise would leave you signed in with no way to say so.
    static func forget(host: String, in store: WKWebsiteDataStore = CanvasWebSession.store) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types).filter {
            host == $0.displayName || host.hasSuffix("." + $0.displayName)
        }
        guard !records.isEmpty else { return }
        await store.removeData(ofTypes: types, for: records)
        Log.write("canvas web session: signed out of \(records.count) record(s)")
    }

    /// Every site, in every jar — the shared one, every named profile, and the old default store, so
    /// nothing is left behind from before the move.
    ///
    /// **Named profiles included, and they have to be.** The item says "all sites" and is the answer to
    /// handing the machine over; a signed-in second account left behind because it was in a different
    /// jar would be the one thing this promised to take care of.
    static func forgetEverything() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
        for name in profileNames {
            await store(named: name).removeData(ofTypes: types, modifiedSince: .distantPast)
        }
        await ephemeral.removeData(ofTypes: types, modifiedSince: .distantPast)
        await WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast)
        Log.write("canvas web session: signed out everywhere")
    }
}
