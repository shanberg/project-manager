import AppKit

/// Every SF Symbol this Mac can draw, with the categories and search keywords the SF Symbols app uses.
///
/// There's no public API that lists symbols, so this reads the metadata the system ships beside them
/// in CoreGlyphs — the same files the SF Symbols app is built from. They're read-only system data in
/// a stable location, and reading them means the picker offers whatever this macOS has rather than a
/// list frozen into the app. If they ever move, the catalog falls back to a short built-in list and
/// the picker keeps working with no categories.
struct SymbolCatalog: Sendable {
    struct Category: Identifiable, Hashable, Sendable {
        let key: String
        let title: String
        let icon: String
        var id: String { key }
    }

    /// Category tabs, in the SF Symbols app's order, "All" excluded — the picker supplies that itself.
    let categories: [Category]
    /// Every offered symbol, grouped by subject: each category's symbols in turn, in the categories'
    /// order, then the few that belong to none. See `load`.
    let symbols: [String]
    private let categoryKeys: [String: Set<String>]
    private let keywords: [String: [String]]

    /// Loaded once, on first use. About 8,000 symbols and three plists, so the first touch should be
    /// off the main thread — see `ProjectSettingsModel`.
    static let shared = SymbolCatalog.load()

    /// The symbols in a category (nil for all) that match a search. A search matches a symbol's name or
    /// its keywords, so "currency" finds `dollarsign.circle`.
    ///
    /// Best match first, so the symbol you meant is at the top rather than wherever the catalog order
    /// put it. A name that *is* the term leads (`heart`, `heart.fill`), then one starting with it
    /// (`heartbeat`), then one with the term as a later word (`suit.heart`), then one merely containing
    /// it, then keyword matches. Within a rank the shorter name wins — `heart.fill` is what you meant,
    /// `heart.text.clipboard.fill` a variation on it — and catalog order breaks what's left.
    func symbols(in category: String?, matching query: String) -> [String] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        let pool = category.map { key in symbols.filter { categoryKeys[$0]?.contains(key) ?? false } } ?? symbols
        guard !terms.isEmpty else { return pool }

        func rank(_ name: String, words: [Substring]) -> Int? {
            var worst = 0
            for term in terms {
                let rank: Int
                if words.first == Substring(term) { rank = 0 }
                else if words.first?.hasPrefix(term) ?? false { rank = 1 }
                else if words.contains(where: { $0.hasPrefix(term) }) { rank = 2 }
                else if name.contains(term) { rank = 3 }
                else if keywords[name]?.contains(where: { $0.hasPrefix(term) }) ?? false { rank = 4 }
                else { return nil }
                worst = max(worst, rank)
            }
            return worst
        }

        return pool.enumerated()
            .compactMap { index, name -> (name: String, rank: Int, length: Int, index: Int)? in
                let words = name.split(separator: ".")
                return rank(name, words: words).map { (name, $0, words.count, index) }
            }
            .sorted { ($0.rank, $0.length, $0.index) < ($1.rank, $1.length, $1.index) }
            .map(\.name)
    }

    // MARK: Loading

    private static let resources = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources"

    /// Categories that describe how a symbol renders rather than what it shows — meaningless here, where
    /// every symbol is drawn as a one-color template — and the SF Symbols app's own "What's New".
    private static let skippedCategories: Set<String> = ["all", "whatsnew", "variable", "multicolor", "draw"]

    private static let categoryTitles: [String: String] = [
        "communication": "Communication", "weather": "Weather", "maps": "Maps",
        "objectsandtools": "Objects & Tools", "devices": "Devices", "cameraandphotos": "Camera & Photos",
        "gaming": "Gaming", "connectivity": "Connectivity", "transportation": "Transportation",
        "automotive": "Automotive", "accessibility": "Accessibility",
        "privacyandsecurity": "Privacy & Security", "human": "Human", "home": "Home",
        "fitness": "Fitness", "nature": "Nature", "editing": "Editing",
        "textformatting": "Text Formatting", "media": "Media", "keyboard": "Keyboard",
        "commerce": "Commerce", "time": "Time", "health": "Health", "shapes": "Shapes",
        "arrows": "Arrows", "indices": "Indices", "math": "Math",
    ]

    /// Script-specific variants (`0.circle.ar`, `character.book.closed.ja`) are the same picture in
    /// another alphabet. A grid of eight 0-circles is noise, so only the base symbol is offered.
    private static let localeSuffixes: Set<String> = [
        "ar", "he", "hi", "ja", "ko", "th", "zh", "rtl", "bn", "gu", "kn", "ml", "mr", "or", "pa",
        "ta", "te", "km", "my", "si", "el", "ru", "mni", "sat", "ps", "fa", "ur", "ne", "as",
        "traditional",
    ]

    private static func plist(_ name: String) -> Any? {
        guard let data = FileManager.default.contents(atPath: "\(resources)/\(name)") else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    static func load() -> SymbolCatalog {
        guard let order = plist("symbol_order.plist") as? [String], !order.isEmpty else { return fallback }

        // Symbols Apple reserves for its own features ("may only be used to refer to Apple's AirPlay").
        let restricted = Set((plist("symbol_restrictions.strings") as? [String: String])?.keys ?? [:].keys)
        let available = availability()
        let offered = order.filter { name in
            guard !restricted.contains(name) else { return false }
            if let last = name.split(separator: ".").last, localeSuffixes.contains(String(last)) { return false }
            return available(name)
        }

        let rawCategories = (plist("symbol_categories.plist") as? [String: [String]]) ?? [:]
        let categoryKeys = rawCategories.mapValues(Set.init)
        let categories = ((plist("categories.plist") as? [[String: String]]) ?? []).compactMap { entry -> Category? in
            guard let key = entry["key"], !skippedCategories.contains(key),
                  let icon = entry["icon"] else { return nil }
            return Category(key: key, title: categoryTitles[key] ?? key.capitalized, icon: icon)
        }
        let keywords = (plist("symbol_search.plist") as? [String: [String]]) ?? [:]

        // `symbol_order.plist` is alphabetical, which opens All on a wall of numbered circles. Browse by
        // subject instead, the way the SF Symbols app's sidebar does: each category's symbols in turn,
        // skipping ones already shown, then whatever belongs to no category. Numbers sit in Indices,
        // one of the last categories, so they end up near the bottom where they belong.
        var members: [String: [String]] = [:]
        for name in offered {
            for key in rawCategories[name] ?? [] { members[key, default: []].append(name) }
        }
        var seen = Set<String>()
        var browse: [String] = []
        for category in categories {
            for name in members[category.key] ?? [] where seen.insert(name).inserted { browse.append(name) }
        }
        browse += offered.filter { !seen.contains($0) }

        return SymbolCatalog(categories: categories, symbols: browse,
                             categoryKeys: categoryKeys, keywords: keywords)
    }

    /// Whether a symbol exists on this macOS, from the year it was introduced and the table mapping
    /// years to releases. Asking `NSImage` eight thousand times would answer the same question slower.
    /// A symbol the table doesn't mention is assumed available — the draw-time check still catches it.
    private static func availability() -> (String) -> Bool {
        guard let table = plist("name_availability.plist") as? [String: Any],
              let years = table["symbols"] as? [String: String],
              let releases = table["year_to_release"] as? [String: [String: String]] else { return { _ in true } }
        let supported: [String: Bool] = releases.mapValues { platforms in
            guard let mac = platforms["macOS"] else { return false }
            let parts = mac.split(separator: ".").compactMap { Int($0) }
            let version = OperatingSystemVersion(majorVersion: parts.first ?? 0,
                                                 minorVersion: parts.count > 1 ? parts[1] : 0,
                                                 patchVersion: parts.count > 2 ? parts[2] : 0)
            return ProcessInfo.processInfo.isOperatingSystemAtLeast(version)
        }
        return { name in years[name].map { supported[$0] ?? false } ?? true }
    }

    private static let fallback = SymbolCatalog(
        categories: [],
        symbols: ["star.fill", "flag.fill", "bookmark.fill", "heart.fill", "bolt.fill", "leaf.fill", "globe",
                  "house.fill", "briefcase.fill", "folder.fill", "book.closed.fill", "hammer.fill",
                  "person.2.fill", "chart.bar.fill", "lightbulb.fill", "sparkles"],
        categoryKeys: [:], keywords: [:])
}
