import Foundation

/// The things you can put on a canvas — the one list of them, and what each is called.
///
/// They were declared twice: "New Card / New Frame / New Link… / New File…" in the board's right-click
/// menu, and "Card / Frame / Link… / File…" in the header's `+`. That is the drift `PMCommand` exists
/// to prevent, arrived on the canvas — two menus a few hundred points apart on screen, offering the
/// same four commands under different names, with nothing but attention keeping them in step.
///
/// **The list, not only the names.** Naming them once wasn't enough: each menu still spelled out its
/// own run of items, so a kind added later (a folder) reached whichever menu somebody remembered and
/// no other. Every surface that offers adding a card — the header's `+`, the board's right-click, a
/// tile's strip and its + — now iterates `offered`, and a new case here is a new item in all of them.
///
/// The full name wins over the bare noun. "Card" is a noun in a list of nouns, which reads as a
/// *kind* rather than an act; "New Card" is a command, which is what a menu item is. It also has to
/// hold its own in the board menu, where it sits above Cut, Paste and Delete — every one of them a
/// verb.
///
/// Where a new card lands is the board's business and differs by surface: the board menu puts one
/// where you right-clicked, the header's `+` in the middle of what you can see, a strip's menu into
/// that tile as a tab. What makes each one is `CanvasBoardView.add(_:at:)`.
enum CanvasAddCommand: CaseIterable {
    case card, frame, link, file
    /// A folder from disk, which the card lists the top level of. Stored as an ordinary file card —
    /// see `CanvasFolderCard` — and asked for on its own because an open panel that takes files and
    /// folders both makes opening a folder mean choosing it.
    case folder
    /// The project's own note — offered only by a board that is a project's and hasn't got it. See
    /// `CanvasProjectNoteCard`, which owns the question of when.
    case projectNote

    /// Ellipses follow the app's convention — a command that opens something further to finish the job
    /// takes one. A card and a frame appear ready to type in; a link, a file and a folder have to ask
    /// which.
    var title: String {
        switch self {
        case .card: return "New Card"
        case .frame: return "New Frame"
        case .link: return "New Link\u{2026}"
        case .file: return "New File\u{2026}"
        case .folder: return "New Folder\u{2026}"
        // No ellipsis: there is nothing to ask. The board already knows which document this is — that
        // is the whole difference between it and New File….
        case .projectNote: return "New Project Note"
        }
    }

    /// Whether what this makes can be a tile. A frame is a container of cards rather than a card, so
    /// there is no tile it could become — adding one to a tiled view would be an edit made entirely
    /// behind it. Dimmed while tiled, and left out of a tile's strip, where every item is a tab.
    var makesTile: Bool { self != .frame }

    /// What to offer, in order. `projectNote` is whether this board is a project's and is missing its
    /// note (`CanvasBoardView.offersProjectNoteCard`) — the item is the board saying something is
    /// missing, so it has nothing to say once it is back.
    static func offered(projectNote: Bool) -> [CanvasAddCommand] {
        allCases.filter { $0 != .projectNote || projectNote }
    }
}
