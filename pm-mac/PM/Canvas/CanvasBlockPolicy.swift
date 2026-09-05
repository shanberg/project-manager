import Foundation

/// Which sites a canvas filters, and the one number WebKit will not negotiate.
///
/// Split out from `CanvasContentBlocker` because these are the decisions worth testing, and the
/// machinery around them needs WebKit, an app bundle and a compiled rule store before it can answer
/// anything at all.
enum CanvasBlockPolicy {
    /// A compiled rule list above this is refused outright, with "Too many rules in JSON array".
    ///
    /// Measured against the macOS 26.5 WebKit: 150,000 rules compile, 150,001 do not. The build
    /// script checks each list against this before shipping it, because the failure arrives at
    /// runtime on somebody else's machine and takes the whole list with it — a list that is one rule
    /// over does not lose one rule, it loses all of them.
    static let ruleCeiling = 150_000

    /// The form a site is remembered in.
    ///
    /// Lowercased, trailing dots dropped, and `www.` treated as noise — so a card on
    /// `www.example.com` and one on `example.com` are one decision rather than two. Anything deeper
    /// than that is left alone: `jira.example.com` is remembered separately from `example.com`,
    /// because a dashboard routinely shows one without the other and quietly widening the exception
    /// to the whole registrable domain would turn filtering off in places nobody asked for.
    static func siteKey(for host: String) -> String {
        var key = host.lowercased()
        while key.hasSuffix(".") { key.removeLast() }
        if key.hasPrefix("www.") { key.removeFirst(4) }
        return key
    }

    /// Whether a card pointed at `host` gets the rule lists attached.
    ///
    /// Filtering is on unless a site has been excused, rather than off until asked for: the cards
    /// that benefit are the ones you didn't think about, and an opt-in list would only ever contain
    /// sites you had already been annoyed by.
    ///
    /// A card with no host — a `file:` URL, or an address that never parsed — is filtered. Rules
    /// keyed to ad domains have nothing to say about such a page, so this costs it nothing, and the
    /// alternative is a hole that opens whenever a URL fails to parse.
    static func filters(_ host: String?, unfiltered: Set<String>) -> Bool {
        guard let host else { return true }
        let key = siteKey(for: host)
        guard !key.isEmpty else { return true }
        return !unfiltered.contains(key)
    }
}
