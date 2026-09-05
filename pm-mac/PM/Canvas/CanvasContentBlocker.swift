import AppKit
import CryptoKit
import WebKit

/// Ad, tracker and cookie-banner filtering for web cards.
///
/// **Why the native path and not a browser extension.** WebKit can host a real MV3 extension —
/// `WKWebExtensionController` loads uBlock Origin Lite, starts its background script and reports its
/// rulesets enabled. It then blocks nothing, because the combined rulesets exceed an undocumented
/// budget, and *nothing in the API says so*: `getEnabledRulesets()` still lists them, and there is no
/// `testMatchOutcome` to ask with. `WKContentRuleList` refuses a list it cannot take, out loud, with
/// a reason — and carries several times as many rules besides. An honest error beats a silent one.
///
/// **Why the lists ship in the bundle.** They are converted from Adblock Plus syntax by AdGuard's
/// SafariConverterLib, which is GPLv3: usable as a build tool that emits data, not as a library
/// inside PM. `scripts/build-blocklists.sh` runs it and commits the result. Fetching them at runtime
/// would keep them fresher, and was built and then removed, because shipping them buys something
/// worth more: every copy of PM runs exactly the rules that were notarised. Nothing varies per
/// machine, so nothing can quietly differ per machine — which matters enormously for a feature whose
/// failures are silent. It also means no network at launch and no dependency on a host being up.
///
/// **Why there is a canary.** A rule list can compile, attach, and still not be applied, and the
/// symptom in PM would be cards that quietly show ads or, past the capacity ceiling, cards that stay
/// blank forever. Neither announces itself. Each published list therefore carries one extra rule that
/// hides an element on a host that cannot resolve, and `verify()` loads a page off the network to ask
/// each list, by name, whether it is actually in force.
@MainActor
enum CanvasContentBlocker {
    /// Sites the user has excused, by `CanvasBlockPolicy.siteKey`.
    private static let unfilteredKey = "PMCanvasUnfilteredSites"
    /// Everything this app compiles is named with this prefix, so stale lists can be told from
    /// whatever else might ever share the store.
    private static let identifierPrefix = "pm.block."
    /// The host the canary rules are keyed to. `.invalid` is reserved by RFC 2606 and resolves
    /// nowhere, so these rules cannot fire on a real page.
    private static let canaryHost = "pm-canary.invalid"

    /// Posted once the canary has an answer, so any open canvas can say so. App-wide rather than
    /// per-window: the lists are one set shared by every board.
    static let healthChanged = Notification.Name("PMCanvasBlockingHealthChanged")

    /// What the canary found wrong, phrased for the notice bar, or nil while everything is in force.
    ///
    /// This exists because the log does not: `Log.isEnabled` is false in a release build, so every
    /// careful diagnostic in this file reaches nobody who has not opted in. A filtering failure is
    /// invisible by nature — the page simply looks like a page — so the one that matters has to be
    /// said in the window.
    private(set) static var trouble: String?

    /// The compiled lists, and the names to ask the canary about. Empty until `prepare()` finishes.
    private(set) static var lists: [WKContentRuleList] = []
    private static var names: [String] = []
    private(set) static var isReady = false
    private static var whenReady: [() -> Void] = []

    /// The compiled form, which *is* a cache: it is derived from files in the bundle and rebuilt in
    /// about thirteen seconds. Keeping ~80 MB of machine-generated state out of Application Support
    /// is the point.
    private static let store: WKContentRuleListStore? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let url = caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.stuarthanberg.pm")
            .appendingPathComponent("ContentRules")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return WKContentRuleListStore(url: url)
    }()

    // MARK: Attaching

    /// Give a configuration the rule lists, unless this site has been excused.
    ///
    /// Per configuration rather than per request, because that is the only granularity WebKit offers:
    /// a list is attached when the web view is built. That is also why excusing a site takes a
    /// rebuild — there is no way to detach from a page already running.
    static func attach(to configuration: WKWebViewConfiguration, for host: String?) {
        guard CanvasBlockPolicy.filters(host, unfiltered: unfilteredSites) else { return }
        for list in lists { configuration.userContentController.add(list) }
    }

    /// Run `block` once the lists are ready, or immediately if they already are.
    ///
    /// Matters on the first launch after an install or an update, where the lists take about thirteen
    /// seconds to compile and a canvas restored at startup can open well inside that window. A card
    /// built before they were ready has no filtering and would keep none until something else made it
    /// reload; this is how it gets a second chance.
    static func onReady(_ block: @escaping () -> Void) {
        if isReady { block() } else { whenReady.append(block) }
    }

    // MARK: The per-site exception

    /// Normalised on the way out as well as in. Everything PM writes here is already in key form;
    /// this is so a set edited by hand — `defaults write com.stuarthanberg.pm
    /// PMCanvasUnfilteredSites -array www.example.com` — does what it plainly means.
    static var unfilteredSites: Set<String> {
        Set((UserDefaults.standard.stringArray(forKey: unfilteredKey) ?? []).map(CanvasBlockPolicy.siteKey))
    }

    static func filters(host: String) -> Bool {
        CanvasBlockPolicy.filters(host, unfiltered: unfilteredSites)
    }

    /// Turn filtering on or off for one site. The caller rebuilds the page; see `attach`.
    static func setFilters(_ on: Bool, host: String) {
        let key = CanvasBlockPolicy.siteKey(for: host)
        guard !key.isEmpty else { return }
        var sites = unfilteredSites
        if on { sites.remove(key) } else { sites.insert(key) }
        UserDefaults.standard.set(Array(sites).sorted(), forKey: unfilteredKey)
        Log.write("canvas blocking: \(on ? "filtering" : "not filtering") \(key)")
    }

    // MARK: Getting ready

    /// Compile — or, normally, look up — every list the bundle ships, then prove they are in force.
    static func prepare() async {
        await compileWhatWeHave()
        isReady = true
        for block in whenReady { block() }
        whenReady.removeAll()
        await verify()
        reportIfNothingLoaded()
    }

    // MARK: Compiling

    private static func compileWhatWeHave() async {
        guard let store else { return Log.write("canvas blocking: no rule store, filtering is off") }
        let files = (Bundle.main.urls(forResourcesWithExtension: "deflate", subdirectory: "BlockLists") ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { return Log.write("canvas blocking: no lists in the bundle") }

        var wanted: Set<String> = []
        var compiledAny = false
        let wall = Date()

        for file in files {
            let name = file.deletingPathExtension().deletingPathExtension().lastPathComponent
            guard let packed = try? Data(contentsOf: file) else { continue }
            // Named by what it contains, so a list that changes in a new release gets a new identity
            // and the previous compilation is never mistaken for the new one. Hashing two megabytes
            // costs a few milliseconds and saves unpacking eighteen.
            let identifier = identifierPrefix + name + "." + digest(packed)
            wanted.insert(identifier)

            if let cached = try? await store.contentRuleList(forIdentifier: identifier) {
                lists.append(cached)
                names.append(name)
                continue
            }
            guard let raw = try? (packed as NSData).decompressed(using: .zlib) as Data else {
                Log.write("canvas blocking: \(name) would not decompress")
                continue
            }
            do {
                let started = Date()
                if let list = try await store.compileContentRuleList(
                    forIdentifier: identifier,
                    encodedContentRuleList: String(decoding: raw, as: UTF8.self)) {
                    lists.append(list)
                    names.append(name)
                    compiledAny = true
                    Log.write(String(format: "canvas blocking: compiled %@ in %.2fs", name,
                                     Date().timeIntervalSince(started)))
                }
            } catch {
                // The reason matters and WebKit gives a good one — "Too many rules in JSON array",
                // "Disjunctions are not supported yet". Losing a list is survivable; losing it
                // without knowing which or why is not.
                let reason = (error as NSError).userInfo["NSHelpAnchor"] ?? error.localizedDescription
                Log.write("canvas blocking: \(name) FAILED — \(reason)")
            }
        }

        Log.write(String(format: "canvas blocking: %d list(s) ready in %.2fs", lists.count,
                         Date().timeIntervalSince(wall)))
        if compiledAny { await prune(store, keeping: wanted) }
    }

    /// Drop compilations of lists this version no longer ships.
    ///
    /// Without this the store keeps every version of every list forever, and these are big: the four
    /// shipped lists compile to something over 80 MB. Only run after a compile, since that is the
    /// only time anything can have been superseded.
    private static func prune(_ store: WKContentRuleListStore, keeping wanted: Set<String>) async {
        let present = await store.availableIdentifiers() ?? []
        for identifier in present where identifier.hasPrefix(identifierPrefix) && !wanted.contains(identifier) {
            try? await store.removeContentRuleList(forIdentifier: identifier)
            Log.write("canvas blocking: removed superseded \(identifier)")
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: The canary

    /// Ask each list, by name, whether it is actually being applied.
    ///
    /// Every shipped list carries a rule that hides `#pm-canary-<name>` on `pm-canary.invalid`.
    /// This loads a page whose base URL is that host — off the network entirely, so it costs nothing
    /// and cannot be confused by a slow site — and reads back the computed style. A list that answers
    /// anything but `none` compiled and attached without taking effect. A page that never answers at
    /// all is the capacity failure, where the web view stops issuing requests entirely; that is why
    /// this gives up rather than waiting.
    private static func verify() async {
        guard !names.isEmpty else { return }
        let configuration = WKWebViewConfiguration()
        for list in lists { configuration.userContentController.add(list) }
        let web = WKWebView(frame: .zero, configuration: configuration)
        let divs = names.map { "<div id=\"pm-canary-\($0)\"></div>" }.joined()
        web.loadHTMLString("<!doctype html><meta charset=utf-8><body>\(divs)</body>",
                           baseURL: URL(string: "https://\(canaryHost)/"))

        let probe = names
            .map { "getComputedStyle(document.getElementById('pm-canary-\($0)')).display" }
            .joined(separator: "+','+")

        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            guard let answer = (try? await web.evaluateJavaScript(probe)) as? String else { continue }
            let states = answer.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard states.count == names.count else { continue }
            let inert = zip(names, states).filter { $0.1 != "none" }.map(\.0)
            if inert.isEmpty {
                Log.write("canvas blocking: verified \(names.count) list(s) in force")
                report(nil)
            } else {
                Log.write("canvas blocking: NOT IN FORCE — \(inert.joined(separator: ", "))")
                report(inert.count == names.count
                    ? "Ad and tracker blocking isn’t working. Web cards will show ads and cookie banners."
                    : "Some ad blocking isn’t working (\(inert.joined(separator: ", "))).")
            }
            return
        }
        Log.write("canvas blocking: canary never answered — the rule lists are stalling page loads")
        report("Ad blocking is stopping pages from loading. Web cards may stay blank.")
    }

    /// Nothing compiled at all is its own kind of wrong, and the canary never runs to notice it.
    private static func reportIfNothingLoaded() {
        guard lists.isEmpty else { return }
        report("Ad blocking is unavailable — no rule lists loaded.")
    }

    private static func report(_ what: String?) {
        guard trouble != what else { return }
        trouble = what
        NotificationCenter.default.post(name: healthChanged, object: nil)
    }
}
