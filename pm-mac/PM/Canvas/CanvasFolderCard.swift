import AppKit
import CoreServices
import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers
import PmLib

// A folder dropped on a board is a Finder window on it.
//
// **A folder is a list, not a file.** What a folder is *for* is what is in it, so the card is the
// Finder's list (or icon) view of it: `CanvasFolderBrowser` draws it, as a real `NSOutlineView` and
// `NSCollectionView`, because selecting, the arrow keys, type-select, renaming in place, Quick Look and
// dragging several items out are what those views *are*.
//
// This file is what the browser reads: one folder's items (`CanvasFolderListing`), kept current while
// the card is up (`CanvasFolderModel`), and the header that names it (`CanvasFolderHeader`).

/// One thing in a folder, with what the Finder shows about it.
struct CanvasFolderEntry: Identifiable, Equatable {
    let url: URL
    let name: String
    /// A folder you can go into. A package — an app, a bundle — is a file here, as it is in the Finder.
    let isFolder: Bool
    var kind = ""
    var type: UTType?
    var modified: Date?
    var created: Date?
    var added: Date?
    /// Spotlight's Date Last Opened — only asked for while the card shows or sorts by it, since it is a
    /// lookup per item. See `CanvasFolderOptions.needsLastOpened`.
    var opened: Date?
    /// Bytes, for a file. Nil for a folder, which would have to be walked to be weighed.
    var size: Int?
    var tags: [CanvasFolderTag] = []
    /// A Finder alias or a symbolic link. Its icon already carries the arrow, as it does in the Finder.
    var isAlias = false
    var sync: CanvasFolderSync = .none
    var id: URL { url }

    /// `url` as the card compares items: symbolic links resolved, so an item read from the folder and
    /// one a command just made — `/var` and `/private/var` — are the same item.
    var key: URL { Self.key(url) }
    static func key(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }
}

/// A Finder tag: its name, and the colour it is drawn in — the Finder's label number, 0 for none.
struct CanvasFolderTag: Equatable {
    let name: String
    let color: Int

    /// The Finder's seven, by their label numbers. Only these have a colour of their own here; a tag
    /// you made keeps whatever colour the Finder gave it, read from the file.
    static let standard: [(name: String, color: Int)] = [
        ("Red", 6), ("Orange", 7), ("Yellow", 5), ("Green", 2), ("Blue", 4), ("Purple", 3), ("Gray", 1),
    ]
}

/// Where a file on a cloud drive stands — Google Drive, Dropbox, iCloud Drive, any File Provider — as
/// the Finder's status column says it. A file on a local disk is `.none`.
enum CanvasFolderSync: Equatable {
    case none
    /// In the cloud and not on this Mac; opening it downloads it.
    case onlineOnly
    case uploading
    case downloading
    /// The upload failed, with the provider's reason.
    case failed(String)

    var isInFlight: Bool { self == .uploading || self == .downloading }

    /// What the provider's own resource values say. Read from `URLResourceValues` so a test can say
    /// what a provider would.
    static func of(isUbiquitous: Bool?, downloading: URLUbiquitousItemDownloadingStatus?,
                   isUploading: Bool?, isDownloading: Bool?, uploadError: Error?) -> CanvasFolderSync {
        guard isUbiquitous == true else { return .none }
        if let uploadError { return .failed(uploadError.localizedDescription) }
        if isUploading == true { return .uploading }
        if isDownloading == true { return .downloading }
        if downloading == .notDownloaded { return .onlineOnly }
        return .none
    }

    /// What the status column says when you point at it.
    var help: String {
        switch self {
        case .none: return ""
        case .onlineOnly: return "Online only. Downloads when you open it."
        case .uploading: return "Uploading"
        case .downloading: return "Downloading"
        case .failed(let reason): return "Upload failed. \(reason)"
        }
    }
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

    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .localizedNameKey, .localizedTypeDescriptionKey, .contentTypeKey,
        .contentModificationDateKey, .creationDateKey, .addedToDirectoryDateKey, .fileSizeKey,
        .isAliasFileKey, .isSymbolicLinkKey, .tagNamesKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadingKey,
        .ubiquitousItemIsDownloadingKey, .ubiquitousItemUploadingErrorKey,
    ]

    /// Read `url`'s top level: hidden files skipped, in `options`' order — folders first while it keeps
    /// them on top. Sorted before the cap, so a folder of thousands sorted by date shows the newest,
    /// not the newest of whichever came first by name.
    static func read(_ url: URL, options: CanvasFolderOptions = CanvasFolderOptions(),
                     limit: Int = limit) -> CanvasFolderListing {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return CanvasFolderListing()
        }
        let entries = urls.map { entry(at: $0, lastOpened: options.needsLastOpened) }.sorted { a, b in
            if options.foldersOnTop, a.isFolder != b.isFolder { return a.isFolder }
            return options.sort.precedes(a, b, ascending: options.ascending)
        }
        return CanvasFolderListing(entries: Array(entries.prefix(limit)), total: entries.count)
    }

    /// `read` in one of the orders, folders on top — what a card did before it had View Options.
    static func read(_ url: URL, sort: CanvasFolderSort, limit: Int = limit) -> CanvasFolderListing {
        var options = CanvasFolderOptions()
        options.sort = sort
        return read(url, options: options, limit: limit)
    }

    static func entry(at item: URL, lastOpened: Bool = false) -> CanvasFolderEntry {
        let values = try? item.resourceValues(forKeys: Set(keys))
        let isFolder = values?.isDirectory == true && values?.isPackage != true
        return CanvasFolderEntry(
            url: item,
            name: values?.localizedName ?? item.lastPathComponent,
            isFolder: isFolder,
            kind: values?.localizedTypeDescription ?? "",
            type: values?.contentType,
            modified: values?.contentModificationDate,
            created: values?.creationDate,
            added: values?.addedToDirectoryDate,
            opened: lastOpened ? Self.lastOpened(item) : nil,
            size: isFolder ? nil : values?.fileSize,
            tags: tags(of: item, names: values?.tagNames),
            isAlias: values?.isAliasFile == true || values?.isSymbolicLink == true,
            sync: .of(isUbiquitous: values?.isUbiquitousItem,
                      downloading: values?.ubiquitousItemDownloadingStatus,
                      isUploading: values?.ubiquitousItemIsUploading,
                      isDownloading: values?.ubiquitousItemIsDownloading,
                      uploadError: values?.ubiquitousItemUploadingError))
    }

    /// A file's tags with their colours, from the tags attribute itself, which stores each as
    /// "Name\nlabel number" — the only place a colour is written down for a tag that isn't one of the
    /// Finder's seven. Read there rather than from `URLResourceValues.tagNames`, which comes back empty
    /// when it is prefetched with the cloud drive's keys, as a directory listing prefetches it.
    static func tags(of url: URL, names: [String]?) -> [CanvasFolderTag] {
        let standard = Dictionary(uniqueKeysWithValues: CanvasFolderTag.standard.map { ($0.name, $0.color) })
        let attribute = "com.apple.metadata:_kMDItemUserTags"
        let size = getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        if size > 0 {
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(url.path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
            if read > 0, let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
                return list.map { item in
                    let parts = item.split(separator: "\n", maxSplits: 1)
                    let name = String(parts.first ?? "")
                    let color = parts.count == 2 ? Int(parts[1]) : nil
                    return CanvasFolderTag(name: name, color: color ?? standard[name] ?? 0)
                }
            }
        }
        return (names ?? []).map { CanvasFolderTag(name: $0, color: standard[$0] ?? 0) }
    }

    /// Spotlight's Date Last Opened — the Finder's column of that name. Nil for something never opened.
    static func lastOpened(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
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
/// removed or renamed at its top level — on the folder showing and on every folder opened under it with
/// its disclosure triangle, and a burst of changes (a copy of forty files) is read once, a moment after
/// it settles.
///
/// **Sync status has no vnode.** An upload finishing changes the provider's records, not the folder, so
/// while anything listed is uploading or downloading the folder is read again every couple of seconds,
/// and not at all once everything has settled.
@MainActor
final class CanvasFolderModel: ObservableObject {
    /// The folder the card is of — what it stores, and where it starts.
    let url: URL
    /// The folder it is showing: `url`, or one inside it that a double-click went into.
    ///
    /// **Kept here and not on the node**, unlike the view settings. Those are how you set the card up;
    /// this is where you happen to be looking, like how far a list is scrolled, and a board opened
    /// tomorrow should show the folder the card is of rather than wherever it was left.
    @Published private(set) var location: URL
    @Published private(set) var listing: CanvasFolderListing
    /// The folders opened under `location` with their disclosure triangles, each with what is in it.
    @Published private(set) var children: [URL: CanvasFolderListing] = [:]
    /// Where files being dragged over the card would go if let go now — the folder showing, or one of
    /// its folder rows — so the card can say so. Nil with nothing over it. See `CanvasFolderDrop`.
    @Published var dropTarget: URL?
    /// How the card lays the folder out, as its node says — kept in step by `CanvasFileNodeView.update`.
    /// A new order is a new read, since the cap is applied after sorting.
    @Published var options: CanvasFolderOptions {
        didSet {
            guard options.readsDifferently(from: oldValue) else { return }
            refresh(force: true)
        }
    }

    private var watches: [URL: DispatchSourceFileSystemObject] = [:]
    private var pending: DispatchWorkItem?
    private var poll: DispatchWorkItem?
    /// How long a folder with something still syncing waits before it is read again.
    static let pollInterval: TimeInterval = 2

    init(url: URL, options: CanvasFolderOptions = CanvasFolderOptions()) {
        self.url = url
        location = url
        self.options = options
        listing = CanvasFolderListing.read(url, options: options)
        watch(url)
        schedulePoll()
    }

    /// Whether the card is showing a folder inside the one it is of, and so has a way back.
    var isInside: Bool { !Self.same(location, url) }

    /// Where the way back goes: the folder the one showing is in.
    var parent: URL { location.deletingLastPathComponent() }

    /// The folders opened with their triangles.
    var expanded: Set<URL> { Set(children.keys) }

    /// Show `folder`, if it is the card's own folder or one inside it. A folder elsewhere is not this
    /// card's to wander into — it answers false, and the caller opens it where folders open.
    @discardableResult
    func go(to folder: URL) -> Bool {
        guard Self.contains(url, folder), CanvasFolderListing.isFolder(folder) else { return false }
        guard !Self.same(folder, location) else { return true }
        unwatchAll()
        children = [:]
        location = folder
        listing = CanvasFolderListing.read(folder, options: options)
        watch(folder)
        schedulePoll()
        return true
    }

    /// Open a folder row with its triangle: read what is in it, and keep watching it.
    func expand(_ folder: URL) {
        guard children[folder] == nil, CanvasFolderListing.isFolder(folder) else { return }
        children[folder] = CanvasFolderListing.read(folder, options: options)
        watch(folder)
        schedulePoll()
    }

    /// Close a folder row — and every folder opened inside it, as the Finder forgets them too.
    func collapse(_ folder: URL) {
        let gone = children.keys.filter { Self.contains(folder, $0) }
        for key in gone {
            children[key] = nil
            unwatch(key)
        }
    }

    /// Read the folder showing and every opened folder again, publishing only what changed.
    func refresh(force: Bool = false) {
        // The folder you were in went away — deleted, or renamed out from under the card. Back to the
        // one the card is of, rather than an empty card with a way back to nowhere.
        if isInside, !CanvasFolderListing.isFolder(location) {
            go(to: url)
            return
        }
        let next = CanvasFolderListing.read(location, options: options)
        if force || next != listing { listing = next }
        var opened = children
        for folder in children.keys {
            guard CanvasFolderListing.isFolder(folder) else {
                opened[folder] = nil
                unwatch(folder)
                continue
            }
            let read = CanvasFolderListing.read(folder, options: options)
            if force || read != opened[folder] { opened[folder] = read }
        }
        if opened != children { children = opened }
        schedulePoll()
    }

    /// Whether anything the card lists is mid-upload or mid-download.
    var hasSyncInFlight: Bool {
        listing.entries.contains { $0.sync.isInFlight }
            || children.values.contains { $0.entries.contains { $0.sync.isInFlight } }
    }

    /// Whether `inner` is `outer` or somewhere under it — compared by path components, so a sibling
    /// whose name merely starts the same ("Docs" and "Docs old") is not inside.
    static func contains(_ outer: URL, _ inner: URL) -> Bool {
        let outer = outer.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let inner = inner.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return inner.count >= outer.count && Array(inner.prefix(outer.count)) == outer
    }

    static func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Stop watching. The card calls this when it goes, since a dispatch source outliving its card is a
    /// file descriptor held open for nothing.
    func stop() {
        pending?.cancel()
        poll?.cancel()
        poll = nil
        unwatchAll()
    }

    private func schedulePoll() {
        poll?.cancel()
        poll = nil
        guard hasSyncInFlight else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        poll = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pollInterval, execute: work)
    }

    private func watch(_ folder: URL) {
        guard watches[folder] == nil else { return }
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.changed() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watches[folder] = source
    }

    private func unwatch(_ folder: URL) {
        watches[folder]?.cancel()
        watches[folder] = nil
    }

    private func unwatchAll() {
        watches.values.forEach { $0.cancel() }
        watches = [:]
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}

/// The card's header: the folder showing, how much is in it, and the way back out of one it went into.
///
/// **The way back is a link**, reported to the card's `CanvasLinkZones`, so the board follows it in
/// place as it does any folder and a drag carries that folder off as a card of its own. Everything
/// else on the header is the board's: it is where you take hold of the card to move it.
struct CanvasFolderHeader: View {
    @ObservedObject var folder: CanvasFolderModel

    var body: some View {
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
                // The status bar says it when it is showing; saying it twice is noise.
                if !folder.options.statusBar {
                    Text(CanvasFolderListing.countLabel(folder.listing.total))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Outside the scroll view, so it says `fixed`.
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

    /// What `image(for:side:)` already has, without asking — so a row drawn again draws its picture at
    /// once rather than its icon first.
    func cached(for entry: CanvasFolderEntry, side: CGFloat) -> NSImage? {
        cache.object(forKey: key(entry, side))
    }

    /// The file's thumbnail at `side` points on a Retina screen, or nil when Quick Look has nothing
    /// better than an icon — in which case the icon is what the card already shows.
    func image(for entry: CanvasFolderEntry, side: CGFloat) async -> NSImage? {
        let key = key(entry, side)
        if let hit = cache.object(forKey: key) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: entry.url, size: CGSize(width: side, height: side),
                                                   scale: 2, representationTypes: .thumbnail)
        guard let made = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        else { return nil }
        cache.setObject(made.nsImage, forKey: key)
        return made.nsImage
    }

    private func key(_ entry: CanvasFolderEntry, _ side: CGFloat) -> NSString {
        "\(entry.url.path)|\(entry.modified?.timeIntervalSinceReferenceDate ?? 0)|\(side)" as NSString
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
