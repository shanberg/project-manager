import Foundation

/// Where a card was last looking, remembered between launches.
///
/// A web card has two addresses: the one written on the board, which is what the card is *for*, and
/// wherever the page has got to since. The second one already survives a pause —
/// `CanvasPageHandover.resumes` is what lets a page frozen on the canvas wake in a workspace tile where
/// you left it — but that is a dictionary in memory, so quitting put every wandered card back on its
/// saved address. You follow three links out of a tracker, close the lid, and the board has forgotten
/// them. Nothing decided that; it is just how far a `static var` reaches.
///
/// So the wandering is written down, and a relaunched card opens where it was. Losing it was never the
/// safe option: Home and Pin are what resolve a wandered card — one puts it back on its address, the
/// other makes where you are the address — and both are offered the moment a card is off its own
/// address. An app that forgets overnight has taken that choice away rather than made it.
///
/// **The address, and never the session.** `interactionState` would bring the scroll position and the
/// back-forward list with it, and it is a blob of WebKit's own making: half-filled form fields, a POST
/// body, whatever the page was holding. That is a thing to keep in memory for the length of a pause,
/// not a thing to write into a file that outlives the session. A URL is what was asked for.
///
/// **Kept out of the `.canvas`,** for `CanvasPageTitles`' reason and with more force: the saved address
/// is something you *set*, and where a page drifted to is something that happened. Writing the second
/// into the document would mean that reading a board edits it — in a file Obsidian also has open and
/// git may well be watching — and it would put the two addresses in one field, which is the one place
/// they must never be.
enum CanvasPageVisits {

    /// Where this card was last seen, if it was somewhere other than its own address.
    static func of(_ card: String) -> URL? {
        guard let entry = stored()[card].flatMap(decode) else { return nil }
        return URL(string: entry.address)
    }

    /// Remember that this card is showing `url`.
    static func remember(_ url: URL, for card: String) {
        guard !card.isEmpty else { return }
        var all = stored()
        // Rewritten even when the address is the one already there, because the timestamp is what keeps
        // a board you open every day from being pruned in favour of one you opened once.
        all[card] = try? JSONEncoder().encode(Entry(address: url.absoluteString, seen: Date()))
        UserDefaults.standard.set(prune(all), forKey: defaultsKey)
    }

    /// Forget where this card was — because it is back on its own address, or because its address
    /// changed and everything remembered about the old one is worthless.
    static func forget(_ card: String) {
        var all = stored()
        guard all.removeValue(forKey: card) != nil else { return }
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }

    // MARK: Where they are kept

    private struct Entry: Codable {
        var address: String
        /// When this card was last seen here, which is what decides who goes when there are too many.
        var seen: Date
    }

    /// How many wandered cards are remembered.
    ///
    /// Only cards that are *off* their address have a row — a card sitting where the board put it is
    /// forgotten rather than recorded, because the board already says where that is. So this counts
    /// the cards you have followed a link out of and not put back, which is a much smaller number than
    /// the cards you own.
    static let capacity = 200

    /// Drop the least recently seen once there are too many.
    ///
    /// An LRU rather than `CanvasViewMemory`'s "is the file still there" — which this could ask, since
    /// the key starts with the canvas's path — because the cost of being wrong is nothing. A row that
    /// outlives its board is read by nobody, and a row pruned too early is a card that opens on its own
    /// address, which is where it would have opened anyway a week ago.
    private static func prune(_ all: [String: Data]) -> [String: Data] {
        guard all.count > capacity else { return all }
        let byAge = all.compactMap { key, data in decode(data).map { (key: key, seen: $0.seen) } }
            .sorted { $0.seen > $1.seen }
        let keeping = Set(byAge.prefix(capacity).map(\.key))
        return all.filter { keeping.contains($0.key) }
    }

    private static let defaultsKey = "PMCanvasPageVisits"

    private static func stored() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }

    private static func decode(_ data: Data) -> Entry? {
        try? JSONDecoder().decode(Entry.self, from: data)
    }
}
