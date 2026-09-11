import Foundation

/// Every emoji, in the groups and order the system's picker uses, plus the ones recently chosen.
///
/// Bundled rather than read from the system: the system's copy is in CoreEmoji's private binary files.
/// `scripts/build-emoji-data.py` trims Unicode's emoji-test.txt into `Resources/Emoji/emoji.json` —
/// rerun it when a new emoji version ships.
struct EmojiCatalog: Sendable {
    struct Emoji: Hashable, Sendable {
        let character: String
        let name: String
    }

    struct Group: Identifiable, Sendable {
        let title: String
        let icon: String
        let emoji: [Emoji]
        var id: String { title }
    }

    let groups: [Group]
    private let names: [String: String]

    static let shared = load()

    func name(of character: String) -> String? { names[character] }

    /// Emoji whose name has a word starting with every term — "red h" finds "red heart", and "cat"
    /// finds the cat without finding "communication".
    func search(_ query: String) -> [Emoji] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        return groups.flatMap(\.emoji).filter { emoji in
            let words = emoji.name.lowercased().split { !$0.isLetter && !$0.isNumber }
            return terms.allSatisfy { term in words.contains { $0.hasPrefix(term) } }
        }
    }

    // MARK: Recently used

    private static let recentsKey = "PMRecentProjectEmoji"
    private static let recentsLimit = 16

    static var recents: [String] { UserDefaults.standard.stringArray(forKey: recentsKey) ?? [] }

    static func noteUsed(_ character: String) {
        let updated = [character] + recents.filter { $0 != character }
        UserDefaults.standard.set(Array(updated.prefix(recentsLimit)), forKey: recentsKey)
    }

    // MARK: Loading

    private struct File: Decodable {
        struct Group: Decodable {
            let name: String
            /// [character, name, emoji version]
            let emoji: [[String]]
        }
        let groups: [Group]
    }

    /// The strip's icons, the same pictures the system's picker uses for its groups.
    private static let icons: [String: String] = [
        "Smileys & People": "face.smiling", "Animals & Nature": "pawprint", "Food & Drink": "fork.knife",
        "Travel & Places": "car", "Activities": "soccerball", "Objects": "lightbulb",
        "Symbols": "heart", "Flags": "flag",
    ]

    static func load() -> EmojiCatalog {
        guard let url = Bundle.main.url(forResource: "emoji", withExtension: "json", subdirectory: "Emoji"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            return EmojiCatalog(groups: [], names: [:])
        }
        let groups = file.groups.map { group in
            Group(title: group.name, icon: icons[group.name] ?? "circle",
                  emoji: group.emoji.compactMap { row in
                      guard row.count >= 3, isDrawable(version: row[2]) else { return nil }
                      return Emoji(character: row[0], name: row[1])
                  })
        }
        let names = Dictionary(groups.flatMap(\.emoji).map { ($0.character, $0.name) },
                               uniquingKeysWith: { first, _ in first })
        return EmojiCatalog(groups: groups, names: names)
    }

    /// Emoji newer than the system's color emoji font draw as an empty box. Anything up to 16.0 is in
    /// every macOS this app runs on (26 and later). 17.0 is gated on 26.4, the point release new emoji
    /// normally arrive in — move the line if a blank box turns up.
    private static func isDrawable(version: String) -> Bool {
        guard let value = Double(version), value > 16.0 else { return true }
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0))
    }
}
