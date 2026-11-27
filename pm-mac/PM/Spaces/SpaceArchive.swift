import Foundation
import PmLib

/// Archived Cards: cards that left a board — a space's Today archived or cleared, or any unpinned card
/// closed, in a space or a project — kept so they can come back after a relaunch. docs/spaces.md
/// § Archived cards.
///
/// - Kept in `~/.config/pm/spaces/archive.json`, every board's together, by `key(spaceID:canvas:)`.
/// - An entry is the whole card (the board's JSON for its node), so a note, file or view card comes
///   back as it was, not just its address.
/// - At most `capacity` per space; older than `maxAge` go.
/// - Read and written on one serial queue, in order. The main thread keeps a copy for the window;
///   the queue's copy is the one written.
/// - Restoring and the window: `SpaceArchiveWindow.swift`.
@MainActor
final class SpaceArchive {
    enum Reason: String, Codable, Sendable {
        /// The space's Archive rule.
        case auto
        /// Today's Clear.
        case cleared
        /// A row's Close.
        case closed

        var label: String {
            switch self {
            case .auto: return "Archived"
            case .cleared: return "Cleared"
            case .closed: return "Closed"
            }
        }
    }

    struct Entry: Codable, Equatable, Identifiable, Sendable {
        var id: String
        /// The board it left (`SpaceArchive.key`): a space's id, or a project board's `canvas:` path.
        /// Named for the spaces it was first kept for, which is what the file says.
        var spaceID: String
        /// The card as the board's file has it.
        var node: JSONValue
        var title: String
        /// A web card's address, and its host.
        var address: String?
        var host: String?
        /// A card that isn't a page: the symbol its row draws.
        var symbol: String?
        var archivedAt: Date
        var reason: Reason

        /// The card again, as it was when it left.
        var card: CanvasNode? { SpaceArchive.node(from: node) }
    }

    static let shared = SpaceArchive(fileURL: SpaceArchive.defaultURL)
    static var defaultURL: URL {
        PMFiles.configDir.appendingPathComponent("spaces", isDirectory: true).appendingPathComponent("archive.json")
    }
    nonisolated static let capacity = 500
    nonisolated static let maxAge: TimeInterval = 90 * 86_400
    static let changed = Notification.Name("SpaceArchiveChanged")

    let fileURL: URL
    /// Every space's entries, newest first. Empty until the file has been read.
    private(set) var entries: [Entry] = []
    /// Bumped by each change made here; the queue's copy is taken only once it has caught up.
    private var generation = 0
    private let io: DispatchQueue
    /// The queue's copy. Only touched on `io`.
    nonisolated(unsafe) private var stored: [Entry]?

    init(fileURL: URL) {
        self.fileURL = fileURL
        io = DispatchQueue(label: "Folio.space-archive", qos: .utility)
        apply { _ in }
    }

    func entries(in spaceID: String) -> [Entry] { entries.filter { $0.spaceID == spaceID } }

    /// The key a board's entries are kept under: a space's own id (what the file has always said), or
    /// `canvas:` and the board file's path for a project's.
    static func key(spaceID: String?, canvas: URL) -> String {
        spaceID ?? "canvas:" + canvas.standardizedFileURL.path
    }

    /// Cards about to come off the board keyed `spaceID`. `titles` by card id, as the sidebar shows
    /// them. Returns each card's new entry, by card id.
    @discardableResult
    func record(_ nodes: [CanvasNode], titles: [String: String], spaceID: String, reason: Reason) -> [String: String] {
        let now = Date()
        let items = Dictionary(
            CanvasItems.sections(of: CanvasDocument(nodes: nodes)).flatMap(\.items).map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a })
        let made: [(card: String, entry: Entry)] = nodes.compactMap { node in
            guard !node.isGroup, let json = Self.json(of: node) else { return nil }
            var address: String?, host: String?, symbol: String?
            switch items[node.id]?.kind {
            case .page(let h)?: host = h
            case .file(let s)?, .view(let s)?: symbol = s
            case .text?: symbol = "text.alignleft"
            case nil: break
            }
            if case .link(let url) = node.content {
                address = url
                host = host ?? URL(string: url)?.host()
            }
            let named = titles[node.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = named.isEmpty ? (items[node.id]?.title ?? host ?? "Untitled") : named
            return (node.id, Entry(id: UUID().uuidString.lowercased(), spaceID: spaceID, node: json, title: title,
                                   address: address, host: host, symbol: symbol, archivedAt: now, reason: reason))
        }
        guard !made.isEmpty else { return [:] }
        let entries = made.map(\.entry)
        apply { $0.insert(contentsOf: entries.reversed(), at: 0) }
        return Dictionary(made.map { ($0.card, $0.entry.id) }, uniquingKeysWith: { a, _ in a })
    }

    func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        apply { $0.removeAll { ids.contains($0.id) } }
    }

    /// Clear Archive…: every entry of the space.
    func clear(spaceID: String) {
        apply { $0.removeAll { $0.spaceID == spaceID } }
    }

    /// Wait for every write asked for so far. At quit, and in tests.
    nonisolated func finish() { io.sync {} }

    /// One change: here at once, then on the queue — read first if it hasn't been — pruned and written.
    private func apply(_ change: @escaping @Sendable (inout [Entry]) -> Void) {
        let now = Date()
        if generation > 0 || !entries.isEmpty {
            change(&entries)
            entries = Self.pruned(entries, now: now)
        }
        generation += 1
        let mine = generation
        let url = fileURL
        let isLoad = mine == 1
        io.async { [self] in
            var all = stored ?? Self.read(url)
            let before = all
            change(&all)
            all = Self.pruned(all, now: now)
            stored = all
            if !isLoad || all != before { Self.write(all, to: url) }
            let copy = all
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // A later change is on its way; its copy will do.
                    guard self.generation == mine else { return }
                    if self.entries != copy { self.entries = copy }
                    NotificationCenter.default.post(name: Self.changed, object: self)
                }
            }
        }
        if mine > 1 { NotificationCenter.default.post(name: Self.changed, object: self) }
    }

    // MARK: The file

    private struct File: Codable {
        var version = 1
        var entries: [Entry]
    }

    nonisolated static func read(_ url: URL) -> [Entry] {
        // read: Folio's own archive.json in ~/.config/pm, on the archive's queue.
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try decoder.decode(File.self, from: data).entries
        } catch {
            Log.write("space archive: couldn't read: \(error)")
            return []
        }
    }

    nonisolated private static func write(_ entries: [Entry], to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(File(entries: entries)).write(to: url, options: .atomic)
        } catch {
            Log.write("space archive: couldn't write: \(error)")
        }
    }

    /// Newest first; at most `capacity` per space, none older than `maxAge`.
    nonisolated static func pruned(_ entries: [Entry], now: Date) -> [Entry] {
        var counts: [String: Int] = [:]
        return entries.sorted { $0.archivedAt > $1.archivedAt }.filter { entry in
            guard now.timeIntervalSince(entry.archivedAt) < maxAge else { return false }
            counts[entry.spaceID, default: 0] += 1
            return counts[entry.spaceID]! <= capacity
        }
    }

    nonisolated private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    nonisolated private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: A card as JSON

    /// The node as the board's file writes it, keys it doesn't know included.
    nonisolated static func json(of node: CanvasNode) -> JSONValue? {
        let text = CanvasDocument(nodes: [node]).serialized()
        guard let any = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return nil }
        return JSONValue(json: any).objectValue?["nodes"]?.arrayValue?.first
    }

    nonisolated static func node(from json: JSONValue) -> CanvasNode? {
        CanvasDocument(fields: ["nodes": .array([json])]).nodes.first
    }

    // MARK: Putting a card back

    /// The card onto `document` as Today, at the top of Today, right of everything on the board.
    /// Returns its id. A card still on the board (⌘Z brought it back) is left as it is.
    static func place(_ card: CanvasNode, into document: inout CanvasDocument) -> String {
        if document.node(id: card.id) != nil { return card.id }
        var node = card
        SpaceCardMarks.setPinned(false, on: &node)
        // Before every numbered card; unnumbered ones follow numbered ones, so this is the top.
        let lowest = document.nodes.filter { !SpaceCardMarks.isPinned($0) }.compactMap(SpaceCardMarks.order).min()
        node.extra[SpaceCardMarks.orderKey] = .number((lowest ?? 0) - 1)
        let right = document.nodes.map(\.frame.maxX).max() ?? 0
        node.frame = CanvasRect(x: right + 40, y: 0, width: node.frame.width, height: node.frame.height)
        document.nodes.append(node)
        return node.id
    }
}
