import AppKit
import PmLib

/// Every page a web card has shown, and the cards closed in spaces. docs/spaces.md § Browsing.
///
/// - Kept in `~/.config/pm/history.json`: one row per address (title, last visit, visit count), newest
///   `capacity` kept.
/// - Recorded from a card's finished loads and its title changes (the second catches sites that move
///   without loading). Not from a Private card, and only http and https.
/// - Read by the History menu, the History window (⌘Y) and the address fields' suggestions.
/// - Closed cards are only for this run: ⇧⌘T takes the newest back.
@MainActor
enum CanvasHistory {
    struct Visit: Codable, Equatable, Identifiable {
        var address: String
        var title: String
        var last: Date
        var count: Int
        var id: String { address }
    }

    static let capacity = 10_000
    static let changed = Notification.Name("CanvasHistoryChanged")
    static var fileURL: URL { PMFiles.configDir.appendingPathComponent("history.json") }

    private static var rows: [String: Visit]?
    private static var saveQueued = false

    private static var all: [String: Visit] {
        if let rows { return rows }
        // read: Folio's own history.json, in ~/.config/pm: local.
        let read = (try? Data(contentsOf: fileURL)).flatMap { try? decoder.decode([Visit].self, from: $0) } ?? []
        let loaded = Dictionary(read.map { ($0.address, $0) }, uniquingKeysWith: { $0.last > $1.last ? $0 : $1 })
        rows = loaded
        return loaded
    }

    /// Newest first.
    static var visits: [Visit] { all.values.sorted { $0.last > $1.last } }

    /// A page was shown. `counts` for a finished load; a title change only names the row (adding it if
    /// it's new).
    static func record(_ url: URL?, title: String?, profile: String?, counts: Bool) {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              profile != CanvasWebSession.ephemeralName else { return }
        let address = url.absoluteString
        var rows = all
        var visit = rows[address] ?? Visit(address: address, title: "", last: Date(), count: 0)
        let named = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !named.isEmpty { visit.title = named }
        if counts || visit.count == 0 {
            visit.count += 1
            visit.last = Date()
        }
        guard rows[address] != visit else { return }
        rows[address] = visit
        self.rows = rows
        save()
    }

    /// History ▸ Clear History…: every row, or those since `since`.
    static func clear(since: Date? = nil) {
        rows = since.map { cutoff in all.filter { $0.value.last < cutoff } } ?? [:]
        save()
    }

    static func remove(_ address: String) {
        rows = all.filter { $0.key != address }
        save()
    }

    private static func save() {
        NotificationCenter.default.post(name: changed, object: nil)
        guard !saveQueued else { return }
        saveQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                saveQueued = false
                flush()
            }
        }
    }

    static func flush() {
        guard let rows else { return }
        let kept = rows.values.sorted { $0.last > $1.last }.prefix(capacity)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try encoder.encode(Array(kept)).write(to: fileURL, options: .atomic)
        } catch {
            Log.write("history: couldn't write: \(error)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: Suggestions

    /// What an address field suggests from: the board's web cards, the card's back list, history
    /// (most visited first, then newest), then pages with a remembered name. Ties go in that order.
    static func candidates(board: [CanvasNode], back: [(title: String, address: String)])
        -> [CanvasAddressSuggestions.Candidate] {
        var candidates: [CanvasAddressSuggestions.Candidate] = []
        for node in board {
            guard case .link(let url) = node.content else { continue }
            let host = URL(string: url)?.host() ?? url
            candidates.append(.init(title: CanvasPageTitles.of(url) ?? host, address: url, source: .board))
        }
        for step in back {
            candidates.append(.init(title: step.title, address: step.address, source: .history))
        }
        let ranked = all.values.sorted { ($0.count, $0.last) > ($1.count, $1.last) }
        for visit in ranked.prefix(2_000) {
            let title = visit.title.isEmpty ? (URL(string: visit.address)?.host() ?? visit.address) : visit.title
            candidates.append(.init(title: title, address: visit.address, source: .history))
        }
        for page in CanvasPageTitles.remembered() {
            candidates.append(.init(title: page.title, address: page.address, source: .history))
        }
        return candidates
    }

    // MARK: Closed cards

    /// A web tile taken out of a layout, in a space or a project: where it was, so ⇧⌘T can show it
    /// again or make it anew.
    struct Closed {
        var address: String
        /// The space it was in; nil for a project's board.
        var spaceID: String?
        /// The board's canvas file, which finds a project's window again.
        var canvas: URL
        var cardID: String
    }

    private(set) static var closed: [Closed] = []

    static func didClose(_ address: String, card: String, canvas: URL, inSpace space: String?) {
        closed.removeAll { $0.cardID == card }
        closed.append(Closed(address: address, spaceID: space, canvas: canvas, cardID: card))
        if closed.count > 50 { closed.removeFirst(closed.count - 50) }
    }

    static func takeLastClosed() -> Closed? { closed.popLast() }
}
