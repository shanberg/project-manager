import Foundation
import PmLib

/// Putting an address into a project's `## Links`, from wherever it was found.
///
/// Two surfaces write this list — the Add Link dialog, and a right-click on a link inside a web card —
/// and the second is why this is a place rather than a block of code inside the first. They have to
/// agree about two things a caller would otherwise decide twice: that the blank row a project with no
/// links carries is filled rather than pushed down, and that a link nobody named is named after the
/// page it points at.
///
/// **Into the notes, still, though a link is a card.** A project's links are web cards in its Links
/// frame, and `## Links` is their mirror (`ProjectLinksFrame`, kept in step by `ProjectLinksSync`). This
/// goes on writing the mirror because that is where its ⌘Z lives — the project's notes history — and
/// the line it writes is a card by the time the notes have been read back, a moment later.
@MainActor
enum ProjectLinks {

    /// Append `address` to this project's links, and give it a name.
    ///
    /// **The name can land second, and on purpose.** What is free — a label you typed, the text of the
    /// link you right-clicked, a title some card has already loaded — goes in with the link in one
    /// step. Only an address nobody can name reaches the network, and then the row appears straight
    /// away and acquires its name a moment later. Holding the write until the page answers would put a
    /// pause between asking for a link and seeing one, on the timeout of a site that may never reply.
    static func add(_ address: String, label: String? = nil, to store: PMStore) {
        let url = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        let typed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Already refused a title that only repeats the address — see `CanvasPageTitles.remember`.
        let known = typed?.isEmpty == false ? typed : CanvasPageTitles.of(url)
        write(LinkEntry(label: known, url: url), to: store)
        guard known == nil else { return }
        // Held strongly for the length of the fetch: the store may be one acquired for this write
        // alone, and the name is no use arriving at a project nobody is left holding.
        Task {
            guard let found = await LinkTitleLoader.shared.title(for: url) else { return }
            name(url, in: store, as: found)
        }
    }

    /// Whether this project already links to `address`, so a surface can say so rather than write a
    /// second row saying the same thing.
    static func has(_ address: String, in store: PMStore) -> Bool {
        let url = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.notes?.links.contains { $0.url == url } ?? false
    }

    /// Add to a project this surface isn't already showing, named by its key.
    ///
    /// **The wait is not optional.** A store acquired for the first time is still reading the notes
    /// file, and `saveDetails` on one that has not resolved its project name yet does nothing at all
    /// and says nothing about it — so a write fired the instant after `acquire` would land or not
    /// depending on how warm the disk was. A store somebody already has open is loaded and this
    /// returns on the same turn.
    ///
    /// The acquisition is given back once the link is in. What happens after that — the fetched name
    /// arriving a few seconds later — holds the store itself rather than a place in the registry,
    /// which is the difference between keeping an object alive and keeping a project open.
    /// `then` is told whether the link was added, which is false only because the project already had
    /// it — and it is said after the wait rather than before, so a surface never announces a write it
    /// turned out not to make.
    static func add(_ address: String, label: String?, toProject key: String,
                    then: (@MainActor (Bool) -> Void)? = nil) {
        let store = StoreRegistry.shared.acquire(key)
        Task { @MainActor in
            await loaded(store)
            defer { StoreRegistry.shared.release(key) }
            let url = address.trimmingCharacters(in: .whitespacesAndNewlines)
            let isNew = !has(url, in: store)
            if isNew { add(url, label: label, to: store) }
            then?(isNew)
        }
    }

    private static func loaded(_ store: PMStore) async {
        await ObservationRelay.wait { store.hasLoaded }
    }

    // MARK: Writing it

    private static func write(_ entry: LinkEntry, to store: PMStore) {
        store.saveDetails { notes in
            var out = notes
            // The model carries one blank entry when a project has no links; fill that rather than
            // leaving an empty row above the first real one.
            if let blank = out.links.firstIndex(where: {
                ($0.label ?? "").isEmpty && ($0.url ?? "").isEmpty && ($0.children ?? []).isEmpty
            }) {
                out.links[blank] = entry
            } else {
                out.links.append(entry)
            }
            return out
        }
    }

    /// Fill in the label of a link that went in without one.
    ///
    /// **Only while it is still blank.** The fetch takes seconds, and in those seconds the row is on
    /// screen in the details brief, where typing a label is the obvious thing to do — so a name that
    /// arrived late must not land on top of one somebody has just written. Checked before the write
    /// rather than inside it, because a `saveDetails` that changes nothing still writes the file and
    /// still pushes an undo step.
    private static func name(_ url: String, in store: PMStore, as label: String) {
        guard let links = store.notes?.links,
              links.contains(where: { $0.url == url && ($0.label ?? "").isEmpty }) else { return }
        store.saveDetails { notes in
            var out = notes
            guard let index = out.links.firstIndex(where: {
                $0.url == url && ($0.label ?? "").isEmpty
            }) else { return notes }
            out.links[index].label = label
            return out
        }
    }
}
