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

    /// Everything one site has stored — its cookies, and the local storage a modern login also uses.
    ///
    /// Matched on the registrable domain, which is what WebKit files a record under: signing out of
    /// `jira.example.com` signs you out of `example.com`, because that is where the session cookie
    /// lives and pretending otherwise would leave you signed in with no way to say so.
    static func forget(host: String) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types).filter {
            host == $0.displayName || host.hasSuffix("." + $0.displayName)
        }
        guard !records.isEmpty else { return }
        await store.removeData(ofTypes: types, for: records)
        Log.write("canvas web session: signed out of \(records.count) record(s)")
    }

    /// Every site, and the old default store too, so nothing is left behind from before the move.
    static func forgetEverything() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
        await WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast)
        Log.write("canvas web session: signed out everywhere")
    }
}
