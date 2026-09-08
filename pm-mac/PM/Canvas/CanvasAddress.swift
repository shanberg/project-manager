import Foundation

/// Turning what somebody typed into an address a web view will actually load.
///
/// One rule in one place, because there are now two ways to type an address at a card — the Add Link
/// box and the header's address field — and they have to agree. The scheme-adding line lived inside the
/// modal dialog, so the field would have shipped either without it (typing `example.com` gives you a
/// card that never loads) or with a second copy of it that drifts.
///
/// **Deliberately not a search box.** A browser's address bar sends anything that isn't an address to a
/// search engine, and PM will not: this app makes one network claim — the pages you put on a board —
/// and quietly handing what you typed to Google would be a second one nobody agreed to. So text that
/// isn't an address is rejected rather than reinterpreted, and the field puts you back where you were.
enum CanvasAddress {
    /// A loadable address, or nil when what was typed isn't one.
    static func normalized(_ typed: String) -> String? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("://") { return URL(string: text) == nil ? nil : text }
        // No scheme, so this has to look enough like a host to be worth guessing at. A dot, or a
        // machine on this Mac — `localhost:3000` is a real thing to point a card at and the only
        // common address with no dot in it.
        let looksLikeHost = !text.contains(where: \.isWhitespace)
            && (text.contains(".") || text.hasPrefix("localhost"))
        guard looksLikeHost else { return nil }
        let guessed = "https://" + text
        return URL(string: guessed) == nil ? nil : guessed
    }
}
