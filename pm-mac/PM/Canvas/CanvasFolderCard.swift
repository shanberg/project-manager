import AppKit
import SwiftUI

/// What a folder dropped on a board shows: its name, how much is in it, and what that is.
///
/// **A folder is a list, not a file.** A dropped folder used to make the same card a document does —
/// its name, centred, in grey — which says there is a folder and nothing about why you put it there
/// (backlog 6). What a folder is *for* is what is in it, so the card is the Finder's list view of its
/// top level: folders first, then everything else, in the Finder's own order.
///
/// **Every row is a link.** Reported to the card's `CanvasLinkZones`, so the board treats a row the
/// way it treats a link in a note: a click opens it where it belongs — a folder in the Finder, a
/// document in its app — and a drag carries it out as a card of its own, the same file card it would
/// have made dropped from the Finder. Nothing needs stepping into first, and the card itself still opens
/// the folder on a double-click, like any file card.
///
/// Stored as the file card it always was — a path, which Obsidian keeps — so nothing about the `.canvas`
/// changes and a board opened in Obsidian still has the card.
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
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(folder.listing.entries) { entry in
                            row(entry)
                        }
                        if folder.listing.total > folder.listing.entries.count {
                            Text("and \(folder.listing.total - folder.listing.entries.count) more")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.url.path))
                .resizable()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.url.lastPathComponent)
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
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .contentShape(Rectangle())
        .reportsLinkZone(entry.url)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isLink)
    }
}

/// One thing in a folder.
struct CanvasFolderEntry: Identifiable, Equatable {
    let url: URL
    let name: String
    /// A folder you can go into. A package — an app, a bundle — is a file here, as it is in the Finder.
    let isFolder: Bool
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

    /// Read `url`'s top level: hidden files skipped, folders first, then the Finder's own name order.
    static func read(_ url: URL, limit: Int = limit) -> CanvasFolderListing {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .localizedNameKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return CanvasFolderListing()
        }
        let entries = urls.map { item -> CanvasFolderEntry in
            let values = try? item.resourceValues(forKeys: Set(keys))
            return CanvasFolderEntry(url: item,
                                     name: values?.localizedName ?? item.lastPathComponent,
                                     isFolder: values?.isDirectory == true && values?.isPackage != true)
        }.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
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
    let url: URL
    @Published private(set) var listing: CanvasFolderListing

    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init(url: URL) {
        self.url = url
        listing = CanvasFolderListing.read(url)
        watch()
    }

    /// Stop watching. The card calls this when it goes, since a dispatch source outliving its card is a
    /// file descriptor held open for nothing.
    func stop() {
        pending?.cancel()
        source?.cancel()
        source = nil
    }

    private func watch() {
        let descriptor = open(url.path, O_EVTONLY)
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
                let next = CanvasFolderListing.read(self.url)
                if next != self.listing { self.listing = next }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
