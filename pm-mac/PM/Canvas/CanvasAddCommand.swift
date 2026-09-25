import Foundation
import PmLib

/// The things you can put on a canvas — the one list of them, what each is called, and which heading
/// it sits under.
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
    // MARK: Cards

    case card
    /// A web card: a live page clipped onto the board, on the shared browser session every card has
    /// always used. See `CanvasLinkNodeView` and docs/web-cards.md.
    case web
    /// The same card, on the ephemeral session — signed in as nobody, never written to disk, gone when
    /// Folio quits (`CanvasWebSession.ephemeralName`).
    ///
    /// **Offered at the point the card is made, because that is when it matters.** A card could always
    /// be put on the private session afterwards, from its own Session submenu — but by then the page
    /// has loaded once in the shared jar, which for the case this is *for* (a link you would rather
    /// your signed-in self didn't follow, a second look at a site as a stranger sees it) is exactly
    /// the thing you were avoiding.
    case privateWeb
    case file
    /// A folder from disk, which the card lists the top level of. Stored as an ordinary file card —
    /// see `CanvasFolderCard` — and asked for on its own because an open panel that takes files and
    /// folders both makes opening a folder mean choosing it.
    case folder
    /// The project's own note — offered only by a board that is a project's and hasn't got it. See
    /// `CanvasProjectNoteCard`, which owns the question of when.
    case projectNote

    // MARK: Views

    /// A Day view: the sittings of today across every project (docs/views.md). A text node carrying
    /// `pmView`, set to another day or narrowed to some projects from its own menu.
    case dayView
    /// A Leftovers view: tasks left open in older sittings, across projects — Day's pair (docs/views.md
    /// D1), the pile where Day is the journal.
    case leftoversView
    /// A Coming up view: what's due across projects, overdue first — the deadline horizon.
    case comingUpView
    /// A Projects view: every project, moving or gone quiet — the portfolio.
    case projectsView
    /// A Time view: where the time went, per project — what a day or a week cost.
    case timeView
    /// A Waiting view: what's being waited on, across projects — the Waiting window's answer, on a board.
    case waitingView
    /// A Search view: tasks across projects matching the words in its field.
    case searchView

    // MARK: Frames

    /// Last, and alone under its heading, because it is the one thing here that is not a card: a frame
    /// is what you draw *around* cards. It is also the one thing a tile cannot be, so in a tab strip
    /// the heading and the item go together (`CanvasBoardView.addCommandItems`).
    case frame

    /// The heading a menu files this under.
    ///
    /// **Because twelve items in a flat run is a list you read rather than a menu you aim at.** The
    /// run grew a kind at a time — a folder, then six views — and each arrival was one more row
    /// between New Card and everything below it. Headings cost three rows and give the eye somewhere
    /// to stop: the views are a block you skip when you want a card, and a block you land in when you
    /// don't.
    enum Group: CaseIterable {
        case cards, views, frames

        /// Plural, unlike the "Card" and "Tile" headers elsewhere in a canvas menu. Those label the
        /// commands for *one* object you right-clicked; these label a class of thing you can make, and
        /// "Cards" is what that class is called.
        var title: String {
            switch self {
            case .cards: return "Cards"
            case .views: return "Views"
            case .frames: return "Frames"
            }
        }
    }

    var group: Group {
        switch self {
        case .card, .web, .privateWeb, .file, .folder, .projectNote: return .cards
        case .dayView, .leftoversView, .comingUpView, .projectsView, .waitingView, .searchView,
             .timeView: return .views
        case .frame: return .frames
        }
    }

    /// Ellipses follow the app's convention — a command that opens something further to finish the job
    /// takes one. A card and a frame appear ready to type in; a web card, a file and a folder have to
    /// ask which.
    ///
    /// **"Web", not "Link".** A link is the address; this makes a *card*, and what the card is is a
    /// live page — which is what the docs, the settings pane and everyone who uses one have called it
    /// for as long as it has embedded the page. "New Link…" read as adding an address to a list, which
    /// is a different command in this app and lives on a project.
    var title: String {
        switch self {
        case .card: return "New Card"
        case .frame: return "New Frame"
        case .web: return "New Web Card\u{2026}"
        case .privateWeb: return "New Private Web Card\u{2026}"
        case .file: return "New File\u{2026}"
        case .folder: return "New Folder\u{2026}"
        // No ellipsis: there is nothing to ask. The board already knows which document this is — that
        // is the whole difference between it and New File….
        case .projectNote: return "New Project Note"
        case .dayView: return "New Day View"
        case .leftoversView: return "New Leftovers View"
        case .comingUpView: return "New Coming Up View"
        case .projectsView: return "New Projects View"
        case .timeView: return "New Time View"
        case .waitingView: return "New Waiting View"
        case .searchView: return "New Search View"
        }
    }

    /// The title on a board that may already know the answer. New Folder on a project's board puts the
    /// project's own folder down without asking (`CanvasProjectNoteCard.projectFolder`), so there it
    /// loses its ellipsis for the reason New Project Note never had one — there is nothing to ask.
    func title(knowsFolder: Bool) -> String {
        self == .folder && knowsFolder ? "New Folder" : title
    }

    /// Whether what this makes can be a tile. A frame is a container of cards rather than a card, so
    /// there is no tile it could become — adding one to a tiled view would be an edit made entirely
    /// behind it. Dimmed while tiled, and left out of a tile's strip, where every item is a tab.
    var makesTile: Bool { self != .frame }

    /// What to offer, in order — which is the order they are declared in, grouped. `projectNote` is
    /// whether this board is a project's and is missing its note
    /// (`CanvasBoardView.offersProjectNoteCard`) — the item is the board saying something is missing,
    /// so it has nothing to say once it is back.
    static func offered(projectNote: Bool) -> [CanvasAddCommand] {
        allCases.filter { $0 != .projectNote || projectNote }
    }

    /// A line of the menu.
    enum Row: Equatable {
        case item(CanvasAddCommand)
        /// The views, under one New View ▸ — seven kinds of card that differ in what they list, not in
        /// how you make them, so they are one choice rather than seven rows.
        case views([CanvasAddCommand])
        case separator
    }

    /// The add list every surface draws: the cards inline, the views one submenu, then the frame —
    /// the one thing here that is not a card — after a line. A tile's strip leaves the frame out.
    static func rows(projectNote: Bool, tabs: Bool) -> [Row] {
        let offered = offered(projectNote: projectNote).filter { !tabs || $0.makesTile }
        var rows: [Row] = offered.filter { $0.group == .cards }.map(Row.item)
        let views = offered.filter { $0.group == .views }
        if !views.isEmpty { rows.append(.views(views)) }
        let frames = offered.filter { $0.group == .frames }
        if !frames.isEmpty { rows.append(.separator) }
        rows += frames.map(Row.item)
        return rows
    }

    /// The kind of view this makes, whose name and glyph New View ▸ shows.
    var viewKind: CanvasViewKind? {
        switch self {
        case .dayView: return .day
        case .leftoversView: return .leftovers
        case .comingUpView: return .comingUp
        case .projectsView: return .projects
        case .timeView: return .time
        case .waitingView: return .waiting
        case .searchView: return .search
        default: return nil
        }
    }

    /// A view's name inside New View ▸, where "New" and "View" are already said.
    var viewName: String? { viewKind?.title }

    /// Said only where the name can't say what the card lists.
    var viewSubtitle: String? {
        switch self {
        case .leftoversView: return "Tasks still open from past sessions"
        case .projectsView: return "Last activity, open tasks, next due"
        default: return nil
        }
    }
}
