import Foundation

/// Which cards the header's `…` is about, and whose commands it offers — the rule, apart from the board.
///
/// **Apart so it can be tested.** The board that builds the menu can't be hosted by the test bundle, and
/// this is the part that decides whether the button is there at all, which is the part that went
/// wrong: the `…` used to appear only for a focused tile or a live page, so a folder selected on the
/// board had no header menu while a folder in a workspace did.
enum CanvasCardActions {
    /// The sort of card, as far as its menu is concerned. A project's notes, a folder and any other file
    /// are one kind of node on disk and three different menus.
    enum Kind: Equatable {
        case project, folder, file, link, text, frame
    }

    struct Target: Equatable {
        /// Every card the menu's commands act on.
        let ids: Set<String>
        /// The card whose own commands lead the menu, or nil when the cards are of different kinds and
        /// only what every card answers to — Cut, Copy, Delete — applies to all of them.
        let anchor: String?
    }

    /// What the `…` is about: the tile you are in, else the page you have stepped into, else the whole
    /// selection. `kind` is nil for anything that isn't a card — a line — and a selection with a line in
    /// it has no card menu, as a line's menu is about the line.
    ///
    /// **Several cards are one menu, as a right-click on several is.** The commands already act on the
    /// selection and say the count when it is more than one ("Reload 4 Cards"); the header
    /// was simply not offering them. A selection of one kind leads with that kind's commands. A mixed
    /// one leads with none, rather than with whichever card happened to be first: a View submenu on a
    /// selection of a folder and a note would look like it applied to both.
    static func target(focused: String?, selection: Set<String>,
                       kind: (String) -> Kind?) -> Target? {
        if let focused { return Target(ids: [focused], anchor: focused) }
        guard !selection.isEmpty else { return nil }
        let kinds = selection.map(kind)
        guard !kinds.contains(nil) else { return nil }
        let anchor = Set(kinds).count == 1 ? selection.min() : nil
        return Target(ids: selection, anchor: anchor)
    }

    /// The tooltip for the `…`, which names what it is about.
    static func help(count: Int, tile: Bool) -> String {
        if count > 1 { return "What these \(count) cards can be told" }
        return tile ? "What this tile can be told" : "What this card can be told"
    }
}
