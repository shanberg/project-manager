import Foundation

/// What the page on a web card calls itself, remembered between launches.
///
/// A link card's whole identity was a favicon and a hostname, which on the boards this feature exists
/// for — eleven cards on one tracker, six pages of one wiki — names none of them. The page has been
/// saying its name the entire time: `WKWebView.title` arrives with every load and was read by nothing.
///
/// **Kept here rather than in the `.canvas`.** `CanvasCardZoom` writes to the file, and the difference
/// is intent: a zoom is something you *set*, so it belongs to the document. A title is derived from a
/// page PM happened to load, and writing it into the file would mean that *looking* at a board edits
/// it — in a document Obsidian also has open and git may well be watching. That is the line
/// `CanvasViewMemory` and `CanvasWorkspaces` already draw, and a cache is on the same side of it as
/// a view state.
///
/// **Keyed by the address, so it is shared.** Every card pointing at a page is named the moment any one
/// of them has loaded it: a duplicated card, the same URL pasted onto a second board, the same
/// dashboard rebuilt next month. Keyed by node id each of those would be anonymous until it had loaded
/// once — which is exactly the moment the name is worth having, since an unloaded card is the one
/// showing you nothing but a globe.
enum CanvasPageTitles {

    /// The name of the page at `address`, if one has ever been seen.
    static func of(_ address: String) -> String? {
        guard let entry = stored()[key(address)].flatMap(decode) else { return nil }
        return entry.title
    }

    /// Remember what the page at `address` calls itself.
    ///
    /// **Titles that name nothing are refused rather than stored.** A page with no `<title>` is
    /// reported by WebKit as its own URL, and a great many sites title themselves with the bare host —
    /// both of which the card is already showing, in a line of its own, underneath. Storing them would
    /// cost a card its second line to repeat its first.
    static func remember(_ title: String, for address: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key(address)
        guard !trimmed.isEmpty, !key.isEmpty, adds(trimmed, to: address) else { return }

        var all = stored()
        // Rewritten even when the title is the one already there, because the timestamp is what keeps
        // a card you look at every day from being pruned in favour of one you opened once.
        all[key] = try? JSONEncoder().encode(Entry(title: trimmed, seen: Date()))
        UserDefaults.standard.set(prune(all), forKey: defaultsKey)
    }

    /// Whether this title says anything the card isn't already saying.
    ///
    /// Compared against the address and its host, both with the scheme, `www.` and any trailing slash
    /// off, because "example.com", "https://example.com/" and "www.example.com" are one answer wearing
    /// three coats and all three turn up as real titles in the wild.
    static func adds(_ title: String, to address: String) -> Bool {
        let name = bare(title)
        guard !name.isEmpty else { return false }
        let host = URL(string: address)?.host().map(bare) ?? ""
        return name != bare(address) && (host.isEmpty || name != host)
    }

    private static func bare(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where value.hasPrefix(scheme) {
            value.removeFirst(scheme.count)
        }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    // MARK: Where they are kept

    private struct Entry: Codable {
        var title: String
        /// When this title was last seen, which is what decides who goes when there are too many. See
        /// `prune`.
        var seen: Date
    }

    /// How many pages are remembered.
    ///
    /// Generous, because the whole value of this is a board opening with its cards already named, and a
    /// person's boards hold what they hold. A row is a URL and a title — call it 200 bytes — so the cap
    /// is measured in tens of kilobytes rather than in anything worth economising on.
    static let capacity = 500

    /// Drop the least recently seen once there are too many.
    ///
    /// A cache with no ceiling is a defaults key that grows for as long as the app is installed.
    /// `CanvasViewMemory` prunes by asking whether the file still exists; there is no equivalent
    /// question to ask about a URL, so this is an ordinary LRU — and losing a row costs nothing worse
    /// than a card that is briefly nameless again.
    private static func prune(_ all: [String: Data]) -> [String: Data] {
        guard all.count > capacity else { return all }
        let byAge = all.compactMap { key, data in decode(data).map { (key: key, seen: $0.seen) } }
            .sorted { $0.seen > $1.seen }
        let keeping = Set(byAge.prefix(capacity).map(\.key))
        return all.filter { keeping.contains($0.key) }
    }

    private static let defaultsKey = "PMCanvasPageTitles"

    private static func stored() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }

    private static func decode(_ data: Data) -> Entry? {
        try? JSONDecoder().decode(Entry.self, from: data)
    }

    /// Trimmed and otherwise left exactly as the board has it. Not lowercased and not otherwise
    /// canonicalised: a URL's path is case-sensitive, and two addresses that differ are two pages
    /// until a redirect says otherwise — which is not a thing to guess at for the sake of a cache hit.
    private static func key(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
