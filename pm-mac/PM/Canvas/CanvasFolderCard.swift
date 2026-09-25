import AppKit
import SwiftUI
import QuickLookThumbnailing
import PmLib

/// What a folder dropped on a board shows: its name, how much is in it, and what that is.
///
/// **A folder is a list, not a file.** A dropped folder used to make the same card a document does —
/// its name, centred, in grey — which says there is a folder and nothing about why you put it there
/// (backlog 6). What a folder is *for* is what is in it, so the card is the Finder's list view of its
/// top level: folders first, then everything else, in the Finder's own order.
///
/// **Every row is a link.** Reported to the card's `CanvasLinkZones`, so the board treats a row the
/// way it treats a link in a note: a click opens a document in its app, and a drag carries it out as a
/// card of its own, the same file card it would have made dropped from the Finder. Nothing needs
/// stepping into first, and the card itself still opens the folder on a double-click, like any file card.
///
/// **A folder is gone into, here.** A click on a folder row used to open it in the Finder, which made
/// the card good for exactly one level: everything below the top was a window somewhere else. Now the
/// card shows it, with a way back in its header (see `CanvasFolderModel.go(to:)`), as a Finder window
/// does. The Finder is still one item away, in the card's menu.
///
/// **Laid out the way you set it.** The card's View menu offers the Finder's list and icon views and its
/// sort orders — see `CanvasFolderOptions` — and Change Folder… points it somewhere else.
///
/// Stored as the file card it always was — a path, which Obsidian keeps, plus the view settings as two
/// optional keys Obsidian ignores — so a board opened in Obsidian still has the card.
struct CanvasFolderCard: View {
    @ObservedObject var folder: CanvasFolderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if folder.listing.entries.isEmpty {
                Text(folder.listing.total == 0 ? "Empty folder" : "Nothing to show")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    switch folder.options.view {
                    case .list: list
                    case .icons: icons
                    }
                }
            }
        }
        // Files over the card and not over one of its folders: the whole card takes them, as a Finder
        // window's list does, and says so the way the Finder does — an accent ring inside its edge.
        .overlay {
            if folder.dropTarget.map(isShowing) == true {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(3)
                    .allowsHitTesting(false)
            }
        }
    }

    private func isShowing(_ url: URL) -> Bool {
        url.standardizedFileURL.path == folder.location.standardizedFileURL.path
    }

    /// A folder row with files over it, which is where they would go.
    private func isDropTarget(_ entry: CanvasFolderEntry) -> Bool {
        folder.dropTarget?.standardizedFileURL.path == entry.url.standardizedFileURL.path
    }

    private var list: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(folder.listing.entries) { entry in
                row(entry)
            }
            more
        }
        .padding(.vertical, 4)
    }

    /// The Finder's icon view: a grid that reflows to the card's width, each item its icon over its name.
    private var icons: some View {
        VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 110), spacing: 4, alignment: .top)],
                      spacing: 6) {
                ForEach(folder.listing.entries) { entry in
                    cell(entry)
                }
            }
            .padding(.horizontal, 8)
            more
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private var more: some View {
        if folder.listing.total > folder.listing.entries.count {
            Text("and \(folder.listing.total - folder.listing.entries.count) more")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if folder.isInside {
                back
            }
            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.location.path))
                .resizable()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.location.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(CanvasFolderListing.countLabel(folder.listing.total))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    /// The way out of a folder the card went into: a link to the folder it is in, which the card follows
    /// in place as it does any folder — so it works without stepping in, like every row, and dragging it
    /// carries that folder off as a card of its own. Outside the scroll view, so it says `fixed`.
    private var back: some View {
        Image(systemName: "chevron.left")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 22)
            .contentShape(Rectangle())
            .reportsLinkZone(folder.parent, fixed: true)
            .help("Back to \(folder.parent.lastPathComponent)")
            .accessibilityLabel(Text("Back to \(folder.parent.lastPathComponent)"))
            .accessibilityAddTraits(.isLink)
    }

    private func row(_ entry: CanvasFolderEntry) -> some View {
        HStack(spacing: 7) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                .resizable()
                .frame(width: 16, height: 16)
            Text(entry.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            // The column the list is sorted by, the one thing a list sorted by date has to show to make
            // sense. Name needs no column: it is already the row.
            if let detail = folder.options.sort.detail(of: entry) {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background { if isDropTarget(entry) { Color.accentColor.opacity(0.25) } }
        .contentShape(Rectangle())
        .reportsLinkZone(entry.url)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isLink)
    }

    private func cell(_ entry: CanvasFolderEntry) -> some View {
        VStack(spacing: 3) {
            CanvasFolderThumbnail(entry: entry, side: 40)
            Text(entry.name)
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background {
            if isDropTarget(entry) { RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.25)) }
        }
        .contentShape(Rectangle())
        .reportsLinkZone(entry.url)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isLink)
    }
}

/// An item in the icon view: what the file looks like, as the Finder's icon view shows it, over the
/// generic icon until that arrives.
///
/// **The picture is the reason to choose icons.** A grid of identical document icons is a list with
/// worse names; a grid of the photographs, pages and slides themselves is how you find the one you
/// meant. A folder keeps its folder icon — its "thumbnail" is the same thing.
struct CanvasFolderThumbnail: View {
    let entry: CanvasFolderEntry
    let side: CGFloat
    @State private var picture: NSImage?

    var body: some View {
        Image(nsImage: picture ?? NSWorkspace.shared.icon(forFile: entry.url.path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: side, height: side)
            // Keyed on the entry, which carries the modification date: a file saved again is drawn again.
            .task(id: entry) {
                picture = entry.isFolder ? nil : await CanvasFolderThumbnails.shared.image(for: entry, side: side)
            }
    }
}

/// Quick Look's pictures of a folder's files, remembered for as long as the app is up.
///
/// Remembered because a card is rebuilt more often than its files change — a re-sort, a resize, the
/// board scrolling it back into view — and each rebuild asking Quick Look again would redraw every icon
/// as a generic one first. Keyed on the file and when it was last written, so an edited file is asked
/// for afresh rather than drawn stale.
@MainActor
final class CanvasFolderThumbnails {
    static let shared = CanvasFolderThumbnails()
    private let cache = NSCache<NSString, NSImage>()

    /// The file's thumbnail at `side` points on a Retina screen, or nil when Quick Look has nothing
    /// better than an icon — in which case the icon is what the card already shows.
    func image(for entry: CanvasFolderEntry, side: CGFloat) async -> NSImage? {
        let key = "\(entry.url.path)|\(entry.modified?.timeIntervalSinceReferenceDate ?? 0)|\(side)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: entry.url, size: CGSize(width: side, height: side),
                                                   scale: 2, representationTypes: .thumbnail)
        guard let made = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        else { return nil }
        cache.setObject(made.nsImage, forKey: key)
        return made.nsImage
    }
}

/// How a folder card is laid out, and the order it lists things in — set from the card's View menu.
///
/// **Kept on the node, in the file**, the bargain `CanvasCardShows` made: this is something you *set*,
/// it is a fact about the card rather than the machine, and two cards on one folder — a list by date
/// beside the icons — are two different cards only if each remembers which it is. Absent keys are the
/// Finder's defaults, so a card never touched writes nothing and an old `.canvas` reads as it always did.
struct CanvasFolderOptions: Equatable {
    var view: CanvasFolderView = .list
    var sort: CanvasFolderSort = .name

    static let viewKey = "pmFolderView"
    static let sortKey = "pmFolderSort"

    /// What `node` says, with anything PM can't read falling back to the default — a hand-edited typo
    /// should draw a folder, not a blank card.
    static func of(_ node: CanvasNode) -> CanvasFolderOptions {
        var options = CanvasFolderOptions()
        if case .string(let raw)? = node.extra[viewKey], let view = CanvasFolderView(rawValue: raw) {
            options.view = view
        }
        if case .string(let raw)? = node.extra[sortKey], let sort = CanvasFolderSort(rawValue: raw) {
            options.sort = sort
        }
        return options
    }

    /// Put these on a card — as the absence of each key at its default, so a card changed and changed
    /// back leaves the file exactly as it found it.
    func set(on node: inout CanvasNode) {
        node.extra[Self.viewKey] = view == .list ? nil : .string(view.rawValue)
        node.extra[Self.sortKey] = sort == .name ? nil : .string(sort.rawValue)
    }
}

/// The Finder's two views that fit a card. Columns and Gallery are ways of walking a tree, and a card
/// is one folder's top level.
enum CanvasFolderView: String, CaseIterable {
    case list, icons

    /// The Finder's own words, from its View menu.
    var title: String {
        switch self {
        case .list: return "as List"
        case .icons: return "as Icons"
        }
    }
}

/// What a folder card sorts by. Folders stay on top whichever it is, as the card always kept them.
enum CanvasFolderSort: String, CaseIterable {
    case name, kind, modified, size

    var title: String {
        switch self {
        case .name: return "Name"
        case .kind: return "Kind"
        case .modified: return "Date Modified"
        case .size: return "Size"
        }
    }

    /// Whether `a` goes before `b`. Dates and sizes run the way the Finder's do on first click — newest
    /// and largest first, since that is the question a sort by either is asking — and anything the two
    /// can't tell apart falls back to the name.
    func precedes(_ a: CanvasFolderEntry, _ b: CanvasFolderEntry) -> Bool {
        switch self {
        case .name: break
        case .kind:
            let order = a.kind.localizedStandardCompare(b.kind)
            if order != .orderedSame { return order == .orderedAscending }
        case .modified:
            if a.modified != b.modified { return (a.modified ?? .distantPast) > (b.modified ?? .distantPast) }
        case .size:
            if a.size != b.size { return (a.size ?? -1) > (b.size ?? -1) }
        }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// What a list row shows beside the name for this sort, or nil when the name is the whole story.
    /// A folder has no size worth saying without walking it, so it says nothing, as the Finder's "--".
    func detail(of entry: CanvasFolderEntry) -> String? {
        switch self {
        case .name: return nil
        case .kind: return entry.kind
        case .modified:
            return entry.modified.map { $0.formatted(.relative(presentation: .named)) }
        case .size:
            guard !entry.isFolder, let size = entry.size else { return nil }
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
    }
}

/// One thing in a folder.
struct CanvasFolderEntry: Identifiable, Equatable {
    let url: URL
    let name: String
    /// A folder you can go into. A package — an app, a bundle — is a file here, as it is in the Finder.
    let isFolder: Bool
    var kind = ""
    var modified: Date?
    /// Bytes, for a file. Nil for a folder, which would have to be walked to be weighed.
    var size: Int?
    var id: URL { url }
}

/// A folder's top level, as the card lists it.
struct CanvasFolderListing: Equatable {
    var entries: [CanvasFolderEntry] = []
    /// Everything that is there, including what the cap left off the list.
    var total = 0

    /// How many rows a card lists before it says how many more there are. A folder of ten thousand
    /// photographs is still a folder you might drop on a board, and listing all of them would be a card
    /// that takes seconds to build to show you the first twenty.
    static let limit = 500

    /// Read `url`'s top level: hidden files skipped, folders first, then in `sort`'s order — the Finder's
    /// own name order by default. Sorted before the cap, so a folder of thousands sorted by date shows
    /// the newest, not the newest of whichever came first by name.
    static func read(_ url: URL, sort: CanvasFolderSort = .name, limit: Int = limit) -> CanvasFolderListing {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .localizedNameKey,
                                      .localizedTypeDescriptionKey, .contentModificationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return CanvasFolderListing()
        }
        let entries = urls.map { item -> CanvasFolderEntry in
            let values = try? item.resourceValues(forKeys: Set(keys))
            let isFolder = values?.isDirectory == true && values?.isPackage != true
            return CanvasFolderEntry(url: item,
                                     name: values?.localizedName ?? item.lastPathComponent,
                                     isFolder: isFolder,
                                     kind: values?.localizedTypeDescription ?? "",
                                     modified: values?.contentModificationDate,
                                     size: isFolder ? nil : values?.fileSize)
        }.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return sort.precedes(a, b)
        }
        return CanvasFolderListing(entries: Array(entries.prefix(limit)), total: entries.count)
    }

    /// "12 items", the way the Finder counts.
    static func countLabel(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    /// Whether `url` is a folder a card should list, rather than a file — a package is a file.
    static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }
}

/// A folder's listing, kept current while the card is up.
///
/// Watched rather than read once, because the card claims to say what is in the folder and a board
/// is left open for days. The watch is the directory's own vnode — it fires when an entry is added,
/// removed or renamed at the top level, which is exactly what the card lists — and a burst of changes
/// (a copy of forty files) is read once, a moment after it settles.
@MainActor
final class CanvasFolderModel: ObservableObject {
    /// The folder the card is of — what it stores, and where it starts.
    let url: URL
    /// The folder it is showing: `url`, or one inside it that a click went into.
    ///
    /// **Kept here and not on the node**, unlike the view and the sort. Those are how you set the card
    /// up; this is where you happen to be looking, like how far a list is scrolled, and a board opened
    /// tomorrow should show the folder the card is of rather than wherever it was left.
    @Published private(set) var location: URL
    @Published private(set) var listing: CanvasFolderListing
    /// Where files being dragged over the card would go if let go now — the folder showing, or one of
    /// its folder rows — so the card can say so. Nil with nothing over it. See `CanvasFolderDrop`.
    @Published var dropTarget: URL?
    /// How the card lays the folder out, as its node says — kept in step by `CanvasFileNodeView.update`.
    /// A new sort is a new read, since the cap is applied after sorting.
    @Published var options: CanvasFolderOptions {
        didSet {
            guard options.sort != oldValue.sort else { return }
            listing = CanvasFolderListing.read(location, sort: options.sort)
        }
    }

    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init(url: URL, options: CanvasFolderOptions = CanvasFolderOptions()) {
        self.url = url
        location = url
        self.options = options
        listing = CanvasFolderListing.read(url, sort: options.sort)
        watch()
    }

    /// Whether the card is showing a folder inside the one it is of, and so has a way back.
    var isInside: Bool { !Self.same(location, url) }

    /// Where the way back goes: the folder the one showing is in.
    var parent: URL { location.deletingLastPathComponent() }

    /// Show `folder`, if it is the card's own folder or one inside it. A folder elsewhere is not this
    /// card's to wander into — it answers false, and the link opens where links go.
    @discardableResult
    func go(to folder: URL) -> Bool {
        guard Self.contains(url, folder), CanvasFolderListing.isFolder(folder) else { return false }
        guard !Self.same(folder, location) else { return true }
        location = folder
        listing = CanvasFolderListing.read(folder, sort: options.sort)
        source?.cancel()
        source = nil
        watch()
        return true
    }

    /// Whether `inner` is `outer` or somewhere under it — compared by path components, so a sibling
    /// whose name merely starts the same ("Docs" and "Docs old") is not inside.
    static func contains(_ outer: URL, _ inner: URL) -> Bool {
        let outer = outer.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let inner = inner.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return inner.count >= outer.count && Array(inner.prefix(outer.count)) == outer
    }

    private static func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Stop watching. The card calls this when it goes, since a dispatch source outliving its card is a
    /// file descriptor held open for nothing.
    func stop() {
        pending?.cancel()
        source?.cancel()
        source = nil
    }

    private func watch() {
        let descriptor = open(location.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.changed() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The folder you were in went away — deleted, or renamed out from under the card. Back
                // to the one the card is of, rather than an empty card with a way back to nowhere.
                if self.isInside, !CanvasFolderListing.isFolder(self.location) {
                    self.go(to: self.url)
                    return
                }
                let next = CanvasFolderListing.read(self.location, sort: self.options.sort)
                if next != self.listing { self.listing = next }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}

/// Files dragged in from outside, filed into a folder card's folder — the Finder's drop, on a board.
///
/// **The Finder's rules, because they are the ones already in your hands.** On the same volume a drop
/// moves and on another it copies; ⌥ makes it a copy and ⌘ a move, which AppKit has already folded
/// into the source's operation mask by the time it reaches here. A file never overwrites another: a
/// name already taken gets the Finder's " 2", as its Keep Both does, since a drop is not the moment to
/// stop and ask. And it undoes, as a Finder move does.
@MainActor
enum CanvasFolderDrop {
    /// What letting go would do, or `[]` for a drop this folder can't take — a folder into itself or
    /// one of its own, or files already here, which the Finder also refuses.
    static func operation(for files: [URL], into folder: URL, allowed: NSDragOperation) -> NSDragOperation {
        guard !files.isEmpty, !isRefused(files, into: folder) else { return [] }
        let canMove = allowed.contains(.move) || allowed.contains(.generic)
        if canMove, files.allSatisfy({ sameVolume($0, folder) }) { return .move }
        if allowed.contains(.copy) { return .copy }
        return canMove ? .move : []
    }

    static func isRefused(_ files: [URL], into folder: URL) -> Bool {
        let into = folder.standardizedFileURL.resolvingSymlinksInPath()
        if files.contains(where: { CanvasFolderModel.contains($0, into) }) { return true }
        return files.allSatisfy {
            $0.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent().path == into.path
        }
    }

    /// Move or copy each file in. Answers what went where, for the undo; stops at the first failure,
    /// having done what it did.
    @discardableResult
    static func perform(_ files: [URL], into folder: URL, copying: Bool,
                        fileManager: FileManager = .default) throws -> [(from: URL, to: URL)] {
        var done: [(from: URL, to: URL)] = []
        for file in files {
            // Already there is left alone — one of several dragged out of this folder and back.
            guard file.standardizedFileURL.deletingLastPathComponent().path
                    != folder.standardizedFileURL.path else { continue }
            let target = freeName(for: file.lastPathComponent, in: folder, fileManager: fileManager)
            if copying {
                try fileManager.copyItem(at: file, to: target)
            } else {
                try fileManager.moveItem(at: file, to: target)
            }
            done.append((file, target))
        }
        return done
    }

    /// `name` in `folder`, or the Finder's next free "name 2.ext", "name 3.ext" when it is taken.
    static func freeName(for name: String, in folder: URL, fileManager: FileManager = .default) -> URL {
        let first = folder.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: first.path) else { return first }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Put a drop back: moved files go home, copies go to the Trash (not deleted — an undo that
    /// destroys is not an undo you can undo).
    static func undo(_ done: [(from: URL, to: URL)], copied: Bool, fileManager: FileManager = .default) {
        for (from, to) in done.reversed() {
            if copied {
                try? fileManager.trashItem(at: to, resultingItemURL: nil)
            } else if !fileManager.fileExists(atPath: from.path) {
                try? fileManager.moveItem(at: to, to: from)
            }
        }
    }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key = URLResourceKey.volumeIdentifierKey
        guard let x = try? a.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject,
              let y = try? b.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject else { return false }
        return x.isEqual(y)
    }
}
