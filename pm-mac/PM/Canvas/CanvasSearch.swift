import Foundation
import PmLib

/// Which cards a search on the board finds.
///
/// Lifted out of `CanvasBoardView+Commands` because the rule is about a document and a query, not a
/// view — and while it lived on the board it could not be tested, because nothing in the test bundle
/// can build a board. `find` and `findNext`, which select and scroll, stay there; this is only the
/// part that decides.
enum CanvasSearch {

    /// Every card whose content mentions `query`, in the order they sit in the file.
    ///
    /// Searches what a card *says* rather than what it stores where the two differ: a file card
    /// matches on its path, so "Flexcompute" finds it, and on its basename, so "Notes.md" does too. A
    /// board of 117 cards is several screens, and the alternative to this is panning until you spot it.
    ///
    /// A web card matches on its address **and on the name of the page at it**, which is the half a
    /// person actually remembers. Eleven cards reading `jira.example.com/browse/PM-4127` are eleven
    /// cards nobody can search; the same eleven are findable the moment "billing" matches the one
    /// called "Billing rollover fails on renewal". The name comes from `CanvasPageTitles`, so it is
    /// there for cards that have never been loaded in this window — which are most of them, on a board
    /// you have just opened.
    ///
    /// A document card matches on **what is written in it** too — a card drawn on the board is a file
    /// (`CanvasDocCards`), and a search that only knew its name would find none of what you wrote.
    /// Only markdown and plain text, and only when the file is found.
    ///
    /// - Parameter pageTitle: The remembered name of the page at an address. Injectable so the rule can
    ///   be tested without the app's defaults; the board passes nothing and gets the real one.
    /// - Parameter fileText: What the file at a stored path says. Nil reads nothing, which is the
    ///   default; the board passes `prose(at:resolver:)`.
    static func matches(_ query: String, in document: CanvasDocument,
                        pageTitle: (String) -> String? = CanvasPageTitles.of,
                        fileText: (String) -> String? = { _ in nil }) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        return document.nodes.filter { node in
            switch node.content {
            case .text(let text): return text.localizedCaseInsensitiveContains(needle)
            case .link(let url):
                return url.localizedCaseInsensitiveContains(needle)
                    || pageTitle(url)?.localizedCaseInsensitiveContains(needle) == true
            case .file(let path, let subpath):
                return path.localizedCaseInsensitiveContains(needle)
                    || (subpath?.localizedCaseInsensitiveContains(needle) ?? false)
                    || fileText(path)?.localizedCaseInsensitiveContains(needle) == true
            case .group(let label, _, _):
                return label?.localizedCaseInsensitiveContains(needle) ?? false
            }
        }
        .map(\.id)
    }

    /// What a markdown or text file card says, read from disk. Nil for any other kind of file, one that
    /// can't be found, and one too large to be a note (over a megabyte), which search skips.
    @MainActor static func prose(at stored: String, resolver: CanvasFileResolver) -> String? {
        guard ["md", "markdown", "txt"].contains((stored as NSString).pathExtension.lowercased()),
              let url = resolver.resolve(stored).url,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_000_000
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
