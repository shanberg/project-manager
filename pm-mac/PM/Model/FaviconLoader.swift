import AppKit
import CryptoKit
import os

/// The app's one favicon fetcher, for the site icons beside a project's links.
///
/// There used to be two — this one, serving the project window's Links block, and a second private
/// copy inside `StatusItemController` serving the menu extra's link items. They did the same job with
/// different timeouts, different user agents, different memories of what had already failed, and no
/// shared cache, so the two surfaces could disagree about which links had icons and each paid for the
/// other's misses. One loader, one policy, one cache.
///
/// Each host is fetched once, directly from the site's own `/favicon.ico` — no third-party favicon
/// service, so nothing outside the linked site itself learns which sites a project links to. A
/// browser card whose host has no `/favicon.ico` may also supply the icon its page declares
/// (`adopt(declared:for:)`); that URL is one the page you are viewing chose, and may sit on the
/// site's CDN, but it is never a service this app picked. Hosts
/// with no usable icon are remembered as misses so nothing retries them, and concurrent asks for one
/// host share a single load.
///
/// **Kept across launches, like a card's snapshot.** A host's icon is written to the caches directory
/// (`Favicons/`, beside `PageSnapshots/`) as the bytes the site sent, filed by a digest of the host,
/// so a relaunch draws every tab and menu item with its icon straight away rather than as globes until
/// the network answers. It is a cache in the directory for caches: derived entirely from sites that were
/// already asked, safe to delete, capped by count, and never a record anyone reads — the names are
/// digests. An entry older than `maxAge` is ignored and fetched again, since sites do change their
/// icons. Misses are *not* kept: a site that had no icon last week may have one now, and a miss costs
/// one request per launch.
///
/// **It can be switched off** (Settings ▸ Projects ▸ Links), and the pane says what it does. This is
/// the only network call the app makes, and the hosts it reaches are read out of a project's own
/// notes — an internal ticket tracker, a client's staging box. An app that otherwise touches the
/// network never owes its user that sentence, and a switch to act on it.
@MainActor
final class FaviconLoader {
    static let shared = FaviconLoader()

    private var cache: [String: NSImage] = [:]
    /// The same icons at menu-item size. Kept separately rather than resizing the cached original,
    /// which is shared with the window's 14pt rows — setting `size` on an `NSImage` changes it for
    /// everyone holding it.
    private var menuSized: [String: NSImage] = [:]
    private var misses: Set<String> = []
    private var inflight: [String: Task<NSImage?, Never>] = [:]

    private init() {}

    /// Whether icons are fetched at all. On by default — the icons are useful and the request goes to
    /// the site you linked and nowhere else — but it is a network call, so it is a switch.
    static let defaultsKey = "PMFetchLinkFavicons"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    func favicon(for host: String) async -> NSImage? {
        guard Self.isEnabled else { return nil }
        let key = host.lowercased()
        guard !key.isEmpty else { return nil }
        if let img = cached(for: key) { return img }
        if misses.contains(key) { return nil }
        if let task = inflight[key] { return await task.value }

        let task = Task<NSImage?, Never> { await Self.fetch(host: key)?.image }
        inflight[key] = task
        let img = await task.value
        inflight[key] = nil
        if let img { cache[key] = img } else { misses.insert(key) }
        return img
    }

    /// The icon a page names in its own markup (`<link rel="icon">`), for a host whose `/favicon.ico`
    /// gave nothing. Plenty of sites serve theirs only this way. Only `https` (or `http` for a
    /// loopback dev server), only for a host with no icon yet, and through the same cookie-less
    /// session — the page you are looking at chose this URL, so it reveals nothing the visit didn't.
    func adopt(declared href: URL, for host: String) async -> NSImage? {
        let key = host.lowercased()
        let local = Self.isLoopback(key)
        guard Self.isEnabled, !key.isEmpty, href.scheme == "https" || (local && href.scheme == "http")
        else { return nil }
        if let img = cache[key] { return img }
        if let task = inflight[key] { _ = await task.value; if let img = cache[key] { return img } }
        guard let got = await Self.fetch(url: href) else { return nil }
        let img = got.image
        // A dev server's icon is not the host's: `localhost` is a different site on every port, so
        // it is held for this session only rather than filed under a name any other server shares.
        if !local { Self.store(got.data, host: key) }
        cache[key] = img
        misses.remove(key)
        menuSized[key] = nil
        return img
    }

    /// What's already in hand, without waiting. For a menu, which is built synchronously in
    /// `menuNeedsUpdate` and can't await anything: it draws whatever has arrived and keeps its link
    /// glyph for the rest, and the next time the menu opens the answer is usually there.
    ///
    /// Falls through to the disk once per host, which is a file of a few hundred bytes — cheap enough
    /// for the draw path, and remembered either way so a host with nothing stored isn't asked twice.
    func cached(for host: String) -> NSImage? {
        let key = host.lowercased()
        if let img = cache[key] { return img }
        guard Self.isEnabled, !key.isEmpty, storeChecked.insert(key).inserted,
              let img = Self.readStored(host: key) else { return nil }
        cache[key] = img
        return img
    }

    private var storeChecked: Set<String> = []

    /// The cached icon at the 16pt an `NSMenuItem` draws, or nil if it hasn't arrived.
    func menuIcon(for host: String) -> NSImage? {
        let key = host.lowercased()
        if let sized = menuSized[key] { return sized }
        guard let image = cache[key], let sized = image.copy() as? NSImage else { return nil }
        sized.size = NSSize(width: 16, height: 16)
        menuSized[key] = sized
        return sized
    }

    /// Start fetching `hosts` that haven't been tried, so a surface that can only read the cache
    /// synchronously has something to read. Already-cached and already-missed hosts cost nothing.
    func warm(hosts: some Sequence<String>) {
        guard Self.isEnabled else { return }
        for host in hosts {
            let key = host.lowercased()
            guard !key.isEmpty, cached(for: key) == nil, !misses.contains(key), inflight[key] == nil else {
                continue
            }
            Task { _ = await favicon(for: key) }
        }
    }

    /// A session with no cookie jar of its own and no share in anyone else's.
    ///
    /// `URLSession.shared` reads the app's cookie storage — the same file WebKit persists a card's
    /// session to — so an icon fetch for `jira.example.com` could carry your Jira session cookie to a
    /// request that has no business having it. An icon is public by definition; nothing about
    /// fetching one should identify you, and this is the one line that guarantees it.
    nonisolated private static let anonymous = URLSession(configuration: .ephemeral)

    nonisolated private static func fetch(host: String) async -> Fetched? {
        guard let url = URL(string: "https://\(host)/favicon.ico") else { return nil }
        guard let got = await fetch(url: url) else { return nil }
        store(got.data, host: host)
        return got
    }

    private struct Fetched: @unchecked Sendable {
        let image: NSImage
        let data: Data
    }

    nonisolated private static func fetch(url: URL) async -> Fetched? {
        let req = URLRequest(url: url, timeoutInterval: 8)
        // No spoofed User-Agent. It used to claim to be Safari, because some hosts refuse
        // `URLSession`'s default agent — but the honest outcome of a host that doesn't want to serve
        // an icon to a task manager is no icon, not a task manager pretending to be a browser. The
        // fallback glyph is already what the row shows while a fetch is in flight, so nothing is
        // missing when this comes back empty.
        do {
            let (data, resp) = try await anonymous.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  data.count <= maxBytes,
                  let img = NSImage(data: data), img.size.width > 0, img.size.height > 0 else { return nil }
            return Fetched(image: img, data: data)
        } catch {
            return nil
        }
    }

    /// `localhost` and friends: plain `http` is fine here, because nothing leaves the machine.
    nonisolated private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
            || host.hasSuffix(".localhost")
    }

    // MARK: Kept across launches

    /// Bigger than any icon worth drawing at 16pt, and a ceiling on what a hostile or broken site can
    /// make us write.
    nonisolated private static let maxBytes = 256 * 1024

    /// How long a stored icon is trusted before it is fetched again.
    nonisolated private static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    /// How many icons survive a quit. A host is one small file, so this is generous.
    nonisolated private static let onDisk = 500

    nonisolated private static let folder: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let url = caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.stuarthanberg.pm")
            .appendingPathComponent("Favicons")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    nonisolated private static func file(for host: String) -> URL? {
        let digest = SHA256.hash(data: Data(host.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder?.appendingPathComponent(digest).appendingPathExtension("ico")
    }

    /// The stored icon for a host, unless it is missing, unreadable, or past `maxAge`.
    nonisolated private static func readStored(host: String) -> NSImage? {
        guard let file = file(for: host),
              let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                  .contentModificationDate,
              Date().timeIntervalSince(modified) < maxAge,
              let data = try? Data(contentsOf: file),
              let img = NSImage(data: data), img.size.width > 0, img.size.height > 0 else { return nil }
        return img
    }

    nonisolated private static func store(_ data: Data, host: String) {
        guard let file = file(for: host) else { return }
        try? data.write(to: file, options: .atomic)
        sweepOnce()
    }

    /// Delete the least recently written once there are too many, once per launch — the same policy,
    /// and for the same reasons, as `CanvasPageSnapshots`.
    nonisolated private static let swept = OSAllocatedUnfairLock(initialState: false)

    nonisolated private static func sweepOnce() {
        let already = swept.withLock { was -> Bool in
            defer { was = true }
            return was
        }
        guard !already, let folder else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys), files.count > onDisk else { return }
        let byAge = files.map { file in
            (file, (try? file.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (file, _) in byAge.dropFirst(onDisk) { try? FileManager.default.removeItem(at: file) }
    }
}
