import PmLib

/// The two rules behind offering a project's own links in the add-a-link field (backlog item 13).
///
/// Lifted out of `CanvasBoardView+Commands` for the same reason `CanvasClipping` was: neither rule is
/// about a view, both have a wrong answer that is invisible until you pick a suggestion, and a value
/// type is something that can be asserted about directly — see `CanvasAddressSuggestionsTests`.
enum CanvasLinkSuggestions {

    /// A project's `## Links`, as `promptForAddress` wants them: the label to show, and the url to
    /// submit when it's picked. The placeholder blank entry a linkless project carries, and anything
    /// else with no url at all, offer nothing — there is no address to suggest.
    static func suggestions(from links: [LinkEntry]) -> [(label: String, url: String)] {
        links.compactMap { entry in
            guard let url = entry.url, !url.isEmpty else { return nil }
            return (entry.label?.isEmpty == false ? entry.label! : url, url)
        }
    }

    /// What typing or picking `entered` in `promptForAddress`'s field actually means: a suggestion's
    /// own url when it was picked (matched by its label, the only thing the field ever shows for one),
    /// or the text itself for anything else — free typing, exactly as the field worked before
    /// suggestions existed.
    static func resolvedAddress(_ entered: String, against suggestions: [(label: String, url: String)]) -> String {
        suggestions.first { $0.label == entered }?.url ?? entered
    }
}
