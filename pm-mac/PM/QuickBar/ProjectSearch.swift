import Foundation

/// Ranks projects against what's been typed into the quick bar.
///
/// Subsequence matching rather than substring, because the useful thing to type at a project called
/// "H-004 Maxwell Carmody" is "hmax" or "carm" — initials and fragments, not a prefix. Scoring then
/// decides which of the matches leads, and the ordering it produces is the whole feature: a list that
/// contains the right project in fourth place is a list you have to read.
enum ProjectSearch {
    struct Candidate {
        let name: String
        /// The name without its "CODE-NNN " prefix.
        let shortName: String
        let code: String
        let isArchived: Bool
    }

    /// Matches for `query`, best first. An empty query matches nothing — the caller shows recents
    /// instead, which is a different list with a different order.
    static func rank<T>(_ items: [T], query: String, candidate: (T) -> Candidate) -> [T] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return items
            .compactMap { item -> (item: T, score: Int)? in
                guard let score = score(candidate(item), needle: needle) else { return nil }
                return (item, score)
            }
            .sorted { $0.score > $1.score }
            .map(\.item)
    }

    /// A project's score for a query, or nil when it doesn't match at all.
    ///
    /// Deliberately coarse — a handful of wide bands rather than a fine-grained metric — so the order
    /// is explainable: an exact code beats a name that starts with the query, which beats a name that
    /// contains it, which beats letters merely scattered through it.
    static func score(_ candidate: Candidate, needle: String) -> Int? {
        let name = candidate.name.lowercased()
        let short = candidate.shortName.lowercased()
        let code = candidate.code.lowercased()

        var score: Int
        if code == needle || name == needle || short == needle {
            score = 1000
        } else if name.hasPrefix(needle) || short.hasPrefix(needle) {
            score = 800
        } else if wordPrefixMatch(short, needle: needle) || wordPrefixMatch(name, needle: needle) {
            // "carm" against "Maxwell Carmody" — the start of any word reads as deliberate.
            score = 600
        } else if needle.count >= Self.minLooseMatchLength, short.contains(needle) || name.contains(needle) {
            score = 400
        } else if needle.count >= Self.minLooseMatchLength, isSubsequence(needle, of: name) {
            score = 200
        } else {
            return nil
        }

        // Shorter names win ties: with two matches equally good, the one carrying less other text is
        // the one the query described more completely.
        score -= min(short.count, 99)
        // Archived projects still match — you do go looking for them — but never ahead of live work.
        if candidate.isArchived { score -= 2000 }
        return score
    }

    /// Below this length, a query has to *start* something — a name, or a word within one.
    ///
    /// Both loose tiers are real ways to find a project: "site" for "Website Refresh", "wref" for the
    /// same. But at one or two characters they stop discriminating. "we" is inside "Maxwell" and
    /// scattered through half of everything else, so at that length the loose tiers return the project
    /// list rather than a match. The strict tiers still work, and two characters is usually a domain
    /// code or the start of a name anyway.
    private static let minLooseMatchLength = 3

    /// True when `needle` starts any whitespace-separated word of `haystack`.
    private static func wordPrefixMatch(_ haystack: String, needle: String) -> Bool {
        haystack.split(whereSeparator: { $0 == " " || $0 == "-" })
            .contains { $0.hasPrefix(needle) }
    }

    /// True when every character of `needle` appears in `haystack`, in order.
    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = Substring(needle)
        for character in haystack {
            if character == remaining.first { remaining = remaining.dropFirst() }
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}
