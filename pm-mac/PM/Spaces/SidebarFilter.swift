import Foundation

/// The sidebar's filter field (docs/spaces.md § Filtering the sidebar): which layouts and cards a
/// typed query keeps, and how they're grouped while it does.
///
/// **The sidebar is the way in, so it has to answer "where is it?".** The board used to be the index of
/// everything on a project — zoom out, read the rectangles. With the board off the sidebar, the list
/// is the index, and a list past a screenful wants a field that narrows it.
///
/// Pure: it knows titles and ids, not a window, so it can be tested without one. `SpaceFrame` hands it
/// the rows it has already read and draws what comes back.
enum SidebarFilter {

    /// A card as the filter sees it: what it's called, where it points, and which folder holds it.
    struct Card: Equatable {
        var id: String
        var title: String
        var host: String? = nil
        var address: String? = nil
        /// The frame it's in on the board, which the sidebar draws as a folder; nil for a loose card.
        var folderID: String? = nil
        var folderLabel: String? = nil
    }

    /// A layout, by name, and the cards it shows.
    struct Layout: Equatable {
        var name: String
        var cards: [String]
    }

    /// The matches under one folder's label, or under none.
    struct Section: Equatable {
        var folderID: String?
        var label: String?
        var cards: [String]
    }

    struct Result: Equatable {
        var layouts: [String] = []
        var sections: [Section] = []
        var isEmpty: Bool { layouts.isEmpty && sections.isEmpty }
        /// Every card kept, in the order drawn: what ↑ and ↓ step through after the layouts.
        var cards: [String] { sections.flatMap(\.cards) }
    }

    /// The query's words. Every one has to be found, in any order: "jira billing" finds the card called
    /// "Billing rollover" on jira.example.com.
    static func words(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// What `query` keeps, or nil for an empty query (the sidebar as it is).
    ///
    /// - A card is kept when every word is in its name, its site, its address or its folder's label —
    ///   so a folder's name finds everything in it — or when `says` holds it: what a card *says* (a
    ///   document's text, a page's remembered title), worked out by `CanvasSearch` over the board.
    /// - A layout is kept when every word is in its name, or when it shows a card that's kept.
    /// - Cards keep the order given (the sidebar's), loose ones first, then each folder where its first
    ///   card came; a card given twice is kept once.
    static func run(_ query: String, cards: [Card], layouts: [Layout], says: Set<String> = []) -> Result? {
        let words = words(query)
        guard !words.isEmpty else { return nil }
        func has(_ text: String?) -> (String) -> Bool {
            { word in text?.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        func found(_ fields: [String?]) -> Bool {
            words.allSatisfy { word in fields.contains { has($0)(word) } }
        }
        var seen = Set<String>(), kept = Set<String>()
        var loose: [String] = [], folders: [Section] = []
        for card in cards where seen.insert(card.id).inserted {
            guard says.contains(card.id)
                    || found([card.title, card.host, card.address, card.folderLabel]) else { continue }
            kept.insert(card.id)
            guard let folder = card.folderID else {
                loose.append(card.id)
                continue
            }
            if let i = folders.firstIndex(where: { $0.folderID == folder }) {
                folders[i].cards.append(card.id)
            } else {
                folders.append(Section(folderID: folder, label: card.folderLabel, cards: [card.id]))
            }
        }
        let layouts = layouts.filter { layout in
            found([layout.name]) || layout.cards.contains(where: kept.contains)
        }.map(\.name)
        let sections = (loose.isEmpty ? [] : [Section(folderID: nil, label: nil, cards: loose)]) + folders
        return Result(layouts: layouts, sections: sections)
    }
}
