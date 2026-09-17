import Foundation

/// Turning what somebody typed into an address a web view will actually load.
///
/// One rule in one place, because there are now two ways to type an address at a card — the Add Link
/// box and the header's address field — and they have to agree. The scheme-adding line lived inside the
/// modal dialog, so the field would have shipped either without it (typing `example.com` gives you a
/// card that never loads) or with a second copy of it that drifts.
///
/// **A search box only once you have said which one.** A browser's address bar sends anything that isn't
/// an address to a search engine, and PM used to refuse to: this app makes one network claim — the pages
/// you put on a board — and quietly handing what you typed to Google would be a second one nobody agreed
/// to. So the engine is a setting, and its default is none (`CanvasSearchEngine`). Picking one is the
/// agreement. Until then, text that isn't an address is rejected rather than reinterpreted, and the
/// field puts you back where you were.
///
/// The Add Link box stays address-only whatever the setting says: a card made from a search is a card
/// pointed at a results page, which is never what somebody pasting into that box meant.
enum CanvasAddress {
    /// Where the header's address field goes with what was typed: the address, if it is one, else a
    /// search on the engine you chose, else nowhere.
    static func resolved(_ typed: String, engine: CanvasSearchEngine) -> String? {
        normalized(typed) ?? engine.searchAddress(for: typed)
    }

    /// An address cut where the site ends: the scheme, host and port, then everything after them.
    ///
    /// The address field draws the two at different strengths, so the part that says *whose* page this
    /// is reads first and a look-alike host can't hide in a long path. An address with no host —
    /// `about:blank`, a `data:` page — is all origin, since there is no site to single out.
    static func splitAtOrigin(_ address: String) -> (origin: String, rest: String) {
        guard let components = URLComponents(string: address),
              let end = components.rangeOfPort?.upperBound ?? components.rangeOfHost?.upperBound,
              components.host?.isEmpty == false
        else { return (address, "") }
        return (String(address[..<end]), String(address[end...]))
    }

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

    /// Whether a page at this address is one to warn about.
    ///
    /// **The header marks the bad answer, not the good one.** The address is drawn there because of a
    /// single argument — during a sign-on you are handed between hosts, and a password field is only
    /// safe to type into if you can see whose it is — and "nobody encrypted this" is the other half of
    /// it. A lock on every https page would be furniture, and furniture is not read.
    ///
    /// **A machine on this Mac is not a warning.** Plain HTTP to `localhost` is how local development
    /// works and how half the cards on a developer's board are pointed; marking those would train the
    /// mark to be ignored, which costs exactly the one page it exists for. Anything that isn't http —
    /// `about:`, `data:`, a card that has never loaded — has no connection to be honest about and is
    /// not warned about either.
    static func isEncrypted(_ address: String) -> Bool {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased() else { return true }
        guard scheme == "http" else { return true }
        let host = url.host()?.lowercased() ?? ""
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
    }
}

/// The search engine the address field hands plain words to, when you have picked one.
///
/// **None by default**, for the reason `CanvasAddress` gives: sending what you type to a third party is
/// a thing you choose, not a thing the app decides for you on first launch. The list is the engines
/// Safari offers plus two that people pick precisely for not being those — every one of them a plain
/// GET with the words in the query string, so there is nothing here but a URL to build.
enum CanvasSearchEngine: String, CaseIterable, Identifiable {
    case none, duckDuckGo, google, bing, ecosia, kagi, startpage

    static let defaultsKey = "PMCanvasSearchEngine"

    /// What Settings has, read at the moment it is needed rather than cached — the field is opened far
    /// less often than the setting could change.
    static var current: CanvasSearchEngine {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(CanvasSearchEngine.init) ?? .none
    }

    var id: String { rawValue }

    var name: String {
        switch self {
        case .none: "None"
        case .duckDuckGo: "DuckDuckGo"
        case .google: "Google"
        case .bing: "Bing"
        case .ecosia: "Ecosia"
        case .kagi: "Kagi"
        case .startpage: "Startpage"
        }
    }

    /// The results page for these words, or nil with no engine or nothing to search for.
    func searchAddress(for typed: String) -> String? {
        let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let (base, parameter) = endpoint,
              var components = URLComponents(string: base) else { return nil }
        components.queryItems = [URLQueryItem(name: parameter, value: words)]
        // `URLQueryItem` leaves `+` alone, and a query string reads a bare `+` as a space — so "c++"
        // would search for "c". Encoded by hand, after the fact, because nothing else in a query needs it.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url?.absoluteString
    }

    private var endpoint: (String, String)? {
        switch self {
        case .none: nil
        case .duckDuckGo: ("https://duckduckgo.com/", "q")
        case .google: ("https://www.google.com/search", "q")
        case .bing: ("https://www.bing.com/search", "q")
        case .ecosia: ("https://www.ecosia.org/search", "q")
        case .kagi: ("https://kagi.com/search", "q")
        case .startpage: ("https://www.startpage.com/sp/search", "query")
        }
    }
}
