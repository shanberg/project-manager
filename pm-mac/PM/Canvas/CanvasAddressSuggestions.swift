import Foundation

/// What the address field offers while you type, and the rest of the address it fills in for you.
///
/// **Only pages this Mac already knows about**: the web cards on the board you are on, the pages whose
/// names `CanvasPageTitles` remembers, and the card's own back list. A browser asks its search engine for
/// suggestions on every keystroke; PM sends nothing until you press Return, whatever engine you picked,
/// because a keystroke is not a decision to search.
///
/// Pure, so the ranking is tested rather than eyeballed — see `CanvasAddressCompletionTests`.
enum CanvasAddressSuggestions {

    struct Suggestion: Equatable, Identifiable {
        enum Source: Equatable { case board, history, search }

        var title: String
        var address: String
        var source: Source

        var id: String { "\(source)|\(address)" }
        /// How the row names where it goes: host and path, no scheme and no `www.`.
        var shownAddress: String { CanvasAddressSuggestions.bare(address) }
    }

    /// A page that could be offered, before anything has been typed.
    struct Candidate: Equatable {
        var title: String
        var address: String
        var source: Suggestion.Source
    }

    /// The rest of an address, filled in after the caret the way Safari does it.
    struct Completion: Equatable {
        /// What the field shows: what you typed, then the part you didn't, selected.
        var text: String
        /// Where Return goes while the completion stands.
        var address: String
    }

    static let limit = 8

    /// The candidates that match `query`, best first, one row per page.
    ///
    /// **Board cards first, at every level of match.** They are the pages this board is *for*, and a
    /// board with a tracker on it wants "iss" to mean that tracker's issues rather than whatever page of
    /// the same site was looked at most recently.
    static func matches(_ query: String, in candidates: [Candidate], limit: Int = limit) -> [Suggestion] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }

        var seen: Set<String> = []
        var scored: [(score: Int, order: Int, suggestion: Suggestion)] = []
        for (order, candidate) in candidates.enumerated() {
            let key = bare(candidate.address)
            guard !key.isEmpty, let score = score(needle, candidate) else { continue }
            // The first appearance of a page wins, so pass the board's cards in ahead of the history.
            guard seen.insert(key).inserted else { continue }
            let boost = candidate.source == .board ? 1 : 0
            scored.append((score * 2 + boost, order,
                           Suggestion(title: candidate.title, address: candidate.address, source: candidate.source)))
        }
        return scored.sorted { ($0.score, -$0.order) > ($1.score, -$1.order) }
            .prefix(limit).map(\.suggestion)
    }

    /// Filling in the address after the caret, from the best match — or nil when what you typed isn't
    /// the start of one.
    ///
    /// **The host first, then the page.** "git" completes to `github.com` rather than to the one issue
    /// you happened to open there, which is what makes it safe to accept by pressing Return; you get the
    /// deeper page by typing into its path, at which point the completion follows you.
    static func completion(for typed: String, from suggestions: [Suggestion]) -> Completion? {
        guard !typed.isEmpty, !typed.contains(where: \.isWhitespace) else { return nil }
        let needle = typed.lowercased()
        for suggestion in suggestions where suggestion.source != .search {
            guard let url = URL(string: suggestion.address), let scheme = url.scheme,
                  let fullHost = url.host(), !fullHost.isEmpty else { continue }
            // Typing the `www.` means matching it; not typing it means matching past it.
            let keepsWWW = needle.hasPrefix("www.")
            let droppedWWW = !keepsWWW && fullHost.lowercased().hasPrefix("www.")
            let host = droppedWWW ? String(fullHost.dropFirst(4)) : fullHost
            let port = url.port.map { ":\($0)" } ?? ""
            let origin = scheme + "://" + (droppedWWW ? "www." : "")

            if (host + port).lowercased().hasPrefix(needle) {
                let rest = String((host + port).dropFirst(typed.count))
                return Completion(text: typed + rest, address: origin + host + port + "/")
            }
            let page = host + port + pathAndQuery(url)
            if page.lowercased().hasPrefix(needle), page.count > typed.count {
                let rest = String(page.dropFirst(typed.count))
                return Completion(text: typed + rest, address: origin + page)
            }
        }
        return nil
    }

    // MARK: Matching

    /// Higher is better; nil is no match.
    private static func score(_ needle: String, _ candidate: Candidate) -> Int? {
        let address = bare(candidate.address)
        let host = address.split(separator: "/", maxSplits: 1).first.map(String.init) ?? address
        if host.hasPrefix(needle) { return 4 }
        if address.hasPrefix(needle) { return 3 }
        let title = candidate.title.lowercased()
        // The start of any word of the title: "iss" finds "Open Issues", "ssues" does not.
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if title.hasPrefix(needle) || words.contains(where: { $0.hasPrefix(needle) }) { return 2 }
        if address.contains(needle) || title.contains(needle) { return 1 }
        return nil
    }

    private static func pathAndQuery(_ url: URL) -> String {
        var text = url.path()
        if let query = url.query() { text += "?" + query }
        return text == "/" ? "" : text
    }

    /// Lowercased, with the scheme, `www.` and any trailing slash off — "example.com",
    /// "https://www.example.com/" and "http://example.com" are one page for the purpose of offering it.
    static func bare(_ address: String) -> String {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = value.range(of: "://") { value.removeSubrange(value.startIndex..<range.upperBound) }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
