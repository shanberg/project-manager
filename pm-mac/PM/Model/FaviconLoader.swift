import AppKit

/// The app's one favicon fetcher, for the site icons beside a project's links.
///
/// There used to be two — this one, serving the project window's Links block, and a second private
/// copy inside `StatusItemController` serving the menu extra's link items. They did the same job with
/// different timeouts, different user agents, different memories of what had already failed, and no
/// shared cache, so the two surfaces could disagree about which links had icons and each paid for the
/// other's misses. One loader, one policy, one cache.
///
/// Each host is fetched once, directly from the site's own `/favicon.ico` — no third-party favicon
/// service, so nothing outside the linked site itself learns which sites a project links to. Hosts
/// with no usable icon are remembered as misses so nothing retries them, and concurrent asks for one
/// host share a single load.
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
        if let img = cache[key] { return img }
        if misses.contains(key) { return nil }
        if let task = inflight[key] { return await task.value }

        let task = Task<NSImage?, Never> { await Self.fetch(host: key) }
        inflight[key] = task
        let img = await task.value
        inflight[key] = nil
        if let img { cache[key] = img } else { misses.insert(key) }
        return img
    }

    /// What's already in hand, without waiting. For a menu, which is built synchronously in
    /// `menuNeedsUpdate` and can't await anything: it draws whatever has arrived and keeps its link
    /// glyph for the rest, and the next time the menu opens the answer is usually there.
    func cached(for host: String) -> NSImage? { cache[host.lowercased()] }

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
            guard !key.isEmpty, cache[key] == nil, !misses.contains(key), inflight[key] == nil else {
                continue
            }
            Task { _ = await favicon(for: key) }
        }
    }

    nonisolated private static func fetch(host: String) async -> NSImage? {
        guard let url = URL(string: "https://\(host)/favicon.ico") else { return nil }
        let req = URLRequest(url: url, timeoutInterval: 8)
        // No spoofed User-Agent. It used to claim to be Safari, because some hosts refuse
        // `URLSession`'s default agent — but the honest outcome of a host that doesn't want to serve
        // an icon to a task manager is no icon, not a task manager pretending to be a browser. The
        // fallback glyph is already what the row shows while a fetch is in flight, so nothing is
        // missing when this comes back empty.
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let img = NSImage(data: data), img.size.width > 0, img.size.height > 0 else { return nil }
            return img
        } catch {
            return nil
        }
    }
}
