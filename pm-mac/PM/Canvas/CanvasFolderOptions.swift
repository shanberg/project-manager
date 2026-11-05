import Foundation
import UniformTypeIdentifiers
import PmLib

/// How one folder card lays its folder out — the Finder's View Options (⌘J), kept per card.
///
/// **On the node, in the file.** These are settings you make, about the card rather than the machine, and
/// two cards on one folder — a list by date beside the icons — are two different cards only if each
/// remembers which it is. Each setting is its own optional key Obsidian ignores, written only where the
/// card differs from the defaults, so a card never touched writes nothing.
///
/// **Defaults are the Finder's "Use as Defaults".** A key a card has not written follows
/// `CanvasFolderOptions.defaults`, which View Options' button sets; until it is pressed the defaults are
/// the built-in ones below.
struct CanvasFolderOptions: Equatable, Codable {
    var view: CanvasFolderView = .list
    var sort: CanvasFolderSort = .name
    /// Against the sort's own first direction — see `CanvasFolderSort.startsAscending`.
    var reversed = false
    var group: CanvasFolderGroup = .none
    /// The list's columns besides Name, in the Finder's order whatever order they were ticked in.
    var columns: [CanvasFolderColumn] = [.modified, .size, .kind] {
        didSet { if columns != orderedColumns { columns = orderedColumns } }
    }
    /// "Today" and "Yesterday" instead of the date.
    var relativeDates = true
    /// Pictures of the files themselves, from Quick Look, instead of their apps' icons.
    var iconPreviews = true
    /// The icon view's icons, in points.
    var iconSize: Double = 64
    var pathBar = true
    var statusBar = false
    var foldersOnTop = true

    var ascending: Bool { sort.startsAscending != reversed }

    /// The columns to show, in the Finder's order.
    var orderedColumns: [CanvasFolderColumn] {
        CanvasFolderColumn.allCases.filter(columns.contains)
    }

    // MARK: Defaults

    private static let defaultsKey = "canvasFolderCardDefaults"

    /// What a card shows for anything it has not set — the built-in values until View Options' Use as
    /// Defaults is pressed.
    static var defaults: CanvasFolderOptions {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let saved = try? JSONDecoder().decode(CanvasFolderOptions.self, from: data) else {
                return CanvasFolderOptions()
            }
            return saved
        }
        set {
            if newValue == CanvasFolderOptions() {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            } else if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: defaultsKey)
            }
        }
    }

    // MARK: On the node

    static let viewKey = "pmFolderView"
    static let sortKey = "pmFolderSort"
    static let reversedKey = "pmFolderReversed"
    static let groupKey = "pmFolderGroup"
    static let columnsKey = "pmFolderColumns"
    static let relativeDatesKey = "pmFolderRelativeDates"
    static let iconPreviewsKey = "pmFolderIconPreviews"
    static let iconSizeKey = "pmFolderIconSize"
    static let pathBarKey = "pmFolderPathBar"
    static let statusBarKey = "pmFolderStatusBar"
    static let foldersOnTopKey = "pmFolderFoldersOnTop"

    /// What `node` says, with anything it doesn't say — or says in a way PM can't read — taken from
    /// `defaults`. A hand-edited typo should draw a folder, not a blank card.
    static func of(_ node: CanvasNode, defaults: CanvasFolderOptions = CanvasFolderOptions.defaults) -> CanvasFolderOptions {
        var options = defaults
        let extra = node.extra
        if case .string(let raw)? = extra[viewKey], let value = CanvasFolderView(rawValue: raw) { options.view = value }
        if case .string(let raw)? = extra[sortKey], let value = CanvasFolderSort(rawValue: raw) { options.sort = value }
        if case .bool(let value)? = extra[reversedKey] { options.reversed = value }
        if case .string(let raw)? = extra[groupKey], let value = CanvasFolderGroup(rawValue: raw) { options.group = value }
        if case .string(let raw)? = extra[columnsKey] {
            options.columns = raw.split(separator: ",").compactMap { CanvasFolderColumn(rawValue: String($0)) }
        }
        if case .bool(let value)? = extra[relativeDatesKey] { options.relativeDates = value }
        if case .bool(let value)? = extra[iconPreviewsKey] { options.iconPreviews = value }
        if case .number(let value)? = extra[iconSizeKey] { options.iconSize = min(128, max(32, value)) }
        if case .bool(let value)? = extra[pathBarKey] { options.pathBar = value }
        if case .bool(let value)? = extra[statusBarKey] { options.statusBar = value }
        if case .bool(let value)? = extra[foldersOnTopKey] { options.foldersOnTop = value }
        return options
    }

    /// Put these on a card: a key for each setting that differs from `defaults`, and none for the rest,
    /// so a card changed and changed back leaves the file exactly as it found it.
    func set(on node: inout CanvasNode, defaults: CanvasFolderOptions = CanvasFolderOptions.defaults) {
        func put(_ key: String, _ differs: Bool, _ value: @autoclosure () -> JSONValue) {
            node.extra[key] = differs ? value() : nil
        }
        put(Self.viewKey, view != defaults.view, .string(view.rawValue))
        put(Self.sortKey, sort != defaults.sort, .string(sort.rawValue))
        put(Self.reversedKey, reversed != defaults.reversed, .bool(reversed))
        put(Self.groupKey, group != defaults.group, .string(group.rawValue))
        put(Self.columnsKey, orderedColumns != defaults.orderedColumns,
            .string(orderedColumns.map(\.rawValue).joined(separator: ",")))
        put(Self.relativeDatesKey, relativeDates != defaults.relativeDates, .bool(relativeDates))
        put(Self.iconPreviewsKey, iconPreviews != defaults.iconPreviews, .bool(iconPreviews))
        put(Self.iconSizeKey, iconSize != defaults.iconSize, .number(iconSize))
        put(Self.pathBarKey, pathBar != defaults.pathBar, .bool(pathBar))
        put(Self.statusBarKey, statusBar != defaults.statusBar, .bool(statusBar))
        put(Self.foldersOnTopKey, foldersOnTop != defaults.foldersOnTop, .bool(foldersOnTop))
    }

    /// Whether going from `old` to this needs the folder read again rather than only drawn again: the
    /// order is applied before the cap, and Date Last Opened is only asked of Spotlight when it is shown.
    func readsDifferently(from old: CanvasFolderOptions) -> Bool {
        sort != old.sort || reversed != old.reversed || foldersOnTop != old.foldersOnTop
            || needsLastOpened != old.needsLastOpened
    }

    /// Whether anything on the card uses Date Last Opened, which costs a Spotlight lookup per item.
    var needsLastOpened: Bool {
        sort == .opened || group == .opened || (view == .list && columns.contains(.opened))
    }

    /// Change the sort the way a click on a column header does: the same column again turns it round,
    /// another column starts in its own first direction.
    mutating func sortBy(_ next: CanvasFolderSort, flipping: Bool) {
        if next == sort {
            if flipping { reversed.toggle() }
        } else {
            sort = next
            reversed = false
        }
    }
}

/// The Finder's two views that fit a card. Columns and Gallery are ways of walking a tree, and a card
/// is one folder.
enum CanvasFolderView: String, CaseIterable, Codable {
    case list, icons

    /// The Finder's own words, from its View menu.
    var title: String {
        switch self {
        case .list: return "as List"
        case .icons: return "as Icons"
        }
    }
}

/// What a folder card sorts by. Folders stay on top, whichever it is, while Keep Folders on Top is on.
enum CanvasFolderSort: String, CaseIterable, Codable {
    case name, kind, opened, added, modified, created, size

    var title: String {
        switch self {
        case .name: return "Name"
        case .kind: return "Kind"
        case .opened: return "Date Last Opened"
        case .added: return "Date Added"
        case .modified: return "Date Modified"
        case .created: return "Date Created"
        case .size: return "Size"
        }
    }

    /// The direction a first click on the column goes, as the Finder's does: A to Z for names and
    /// kinds, newest and largest first for dates and sizes, since that is the question a sort by
    /// either is asking.
    var startsAscending: Bool { self == .name || self == .kind }

    /// Whether `a` goes before `b`, folders aside. Anything the key can't tell apart falls back to the
    /// name, in the Finder's order — where "file 2" comes before "file 10".
    func precedes(_ a: CanvasFolderEntry, _ b: CanvasFolderEntry, ascending: Bool) -> Bool {
        let byName = a.name.localizedStandardCompare(b.name)
        func ordered(_ order: ComparisonResult) -> Bool {
            if order == .orderedSame { return byName == .orderedAscending }
            return (order == .orderedAscending) == ascending
        }
        switch self {
        case .name:
            return byName == .orderedSame ? false : (byName == .orderedAscending) == ascending
        case .kind: return ordered(a.kind.localizedStandardCompare(b.kind))
        case .opened: return ordered(Self.compare(a.opened, b.opened))
        case .added: return ordered(Self.compare(a.added, b.added))
        case .modified: return ordered(Self.compare(a.modified, b.modified))
        case .created: return ordered(Self.compare(a.created, b.created))
        case .size:
            let x = a.size ?? -1, y = b.size ?? -1
            return ordered(x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending))
        }
    }

    private static func compare(_ a: Date?, _ b: Date?) -> ComparisonResult {
        let x = a ?? .distantPast, y = b ?? .distantPast
        return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
    }
}

/// A column the list can show besides Name, in the order the Finder lays them out.
enum CanvasFolderColumn: String, CaseIterable, Codable {
    case modified, created, opened, added, size, kind

    var title: String { sort.title }

    /// What a click on its header sorts by.
    var sort: CanvasFolderSort {
        switch self {
        case .modified: return .modified
        case .created: return .created
        case .opened: return .opened
        case .added: return .added
        case .size: return .size
        case .kind: return .kind
        }
    }

    var isDate: Bool { self != .size && self != .kind }
}

/// What a folder card groups its items under, as the Finder's Use Groups does.
enum CanvasFolderGroup: String, CaseIterable, Codable {
    case none, kind, opened, added, modified, created, size, tags

    var title: String {
        switch self {
        case .none: return "None"
        case .kind: return "Kind"
        case .opened: return "Date Last Opened"
        case .added: return "Date Added"
        case .modified: return "Date Modified"
        case .created: return "Date Created"
        case .size: return "Size"
        case .tags: return "Tags"
        }
    }

    /// The groups `entries` fall into, in the order they are drawn, each with its entries in the order
    /// they came. Empty groups are left out.
    func groups(of entries: [CanvasFolderEntry], now: Date = Date(),
                calendar: Calendar = .current) -> [(title: String, entries: [CanvasFolderEntry])] {
        guard self != .none else { return [("", entries)] }
        var order: [String] = []
        var members: [String: [CanvasFolderEntry]] = [:]
        for entry in entries {
            let title = title(for: entry, now: now, calendar: calendar)
            if members[title] == nil { order.append(title) }
            members[title, default: []].append(entry)
        }
        let fixed = fixedOrder
        let sorted = fixed.isEmpty ? order : order.sorted { a, b in
            (fixed.firstIndex(of: a) ?? .max) < (fixed.firstIndex(of: b) ?? .max)
        }
        return sorted.map { ($0, members[$0] ?? []) }
    }

    /// The order a kind of grouping draws its groups in, where it has one. Tags are drawn in the order
    /// their items first appear.
    private var fixedOrder: [String] {
        switch self {
        case .none, .tags: return []
        case .kind: return ["Folders", "Documents", "Images", "Movies", "Music", "Presentations",
                            "Spreadsheets", "Archives", "Applications", "Other"]
        case .size: return ["Folders", "Over 1 GB", "100 MB to 1 GB", "1 MB to 100 MB", "Under 1 MB"]
        case .opened, .added, .modified, .created:
            return ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "Earlier", "Never"]
        }
    }

    private func title(for entry: CanvasFolderEntry, now: Date, calendar: Calendar) -> String {
        switch self {
        case .none: return ""
        case .tags: return entry.tags.first?.name ?? "No Tags"
        case .kind: return Self.kindGroup(entry)
        case .size:
            guard !entry.isFolder, let size = entry.size else { return "Folders" }
            if size >= 1_000_000_000 { return "Over 1 GB" }
            if size >= 100_000_000 { return "100 MB to 1 GB" }
            if size >= 1_000_000 { return "1 MB to 100 MB" }
            return "Under 1 MB"
        case .opened: return Self.dateGroup(entry.opened, now: now, calendar: calendar)
        case .added: return Self.dateGroup(entry.added, now: now, calendar: calendar)
        case .modified: return Self.dateGroup(entry.modified, now: now, calendar: calendar)
        case .created: return Self.dateGroup(entry.created, now: now, calendar: calendar)
        }
    }

    static func kindGroup(_ entry: CanvasFolderEntry) -> String {
        if entry.isFolder { return "Folders" }
        guard let type = entry.type else { return "Other" }
        if type.conforms(to: .application) { return "Applications" }
        if type.conforms(to: .image) { return "Images" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "Movies" }
        if type.conforms(to: .audio) { return "Music" }
        if type.conforms(to: .presentation) { return "Presentations" }
        if type.conforms(to: .spreadsheet) { return "Spreadsheets" }
        if type.conforms(to: .archive) { return "Archives" }
        if type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .compositeContent)
            || type.conforms(to: .content) { return "Documents" }
        return "Other"
    }

    static func dateGroup(_ date: Date?, now: Date, calendar: Calendar) -> String {
        guard let date else { return "Never" }
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days <= 7 { return "Previous 7 Days" }
        if days <= 30 { return "Previous 30 Days" }
        return "Earlier"
    }
}
