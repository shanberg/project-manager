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
    /// - Parameter pageTitle: The remembered name of the page at an address. Injectable so the rule can
    ///   be tested without the app's defaults; the board passes nothing and gets the real one.
    static func matches(_ query: String, in document: CanvasDocument,
                        pageTitle: (String) -> String? = CanvasPageTitles.of) -> [String] {
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
            case .group(let label, _, _):
                return label?.localizedCaseInsensitiveContains(needle) ?? false
            }
        }
        .map(\.id)
    }
}
