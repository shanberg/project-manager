import Foundation
import WebKit

/// Which board a card's page runs on, when more than one board is showing the card.
///
/// **Every tab is a board of its own** — see `ProjectContentPaneController` — so the canvas and each of
/// its workspaces hold their own view of the same card, and each used to build its own page. Switching
/// from the canvas to a workspace put a second, fresh copy of every page in the tiles: the one you had
/// scrolled, signed in to, followed a link out of or half filled in went on running in a tab you could
/// no longer see, and the tile started again from the address saved on the board.
///
/// **A page belongs to the card, not to the board.** There is one per card, and it goes to whichever
/// board you are looking at: a board coming forward takes the page from the tab behind it rather than
/// starting another, and the web view moves across with everything the page was holding. What moves is
/// the renderer itself, so this is also one renderer where there used to be two.
///
/// Two windows on one project are both in sight, and each keeps a page of its own. Taking a page from a
/// window you can see would empty a card in front of you, and the next glance at it would take it back.
@MainActor
enum CanvasPageHandover {
    /// Where the page is, when some other board's copy of the card has it running.
    enum Holder: Equatable { case inSight, outOfSight }

    enum Decision: Equatable {
        /// Take the running page from the board that has it.
        case adopt
        /// Build one — nobody else has it, or they are showing theirs.
        case start
        /// Leave it alone.
        case wait
    }

    /// What a card should do when its board says to run a page.
    ///
    /// **A board out of sight neither takes a page nor starts one.** The first half is what stops two
    /// tabs trading a page back and forth on every budget pass. The second is that a renderer built
    /// behind another tab is all cost: nobody can see it, and the board in front would only take it.
    static func decide(inSight: Bool, holder: Holder?) -> Decision {
        guard inSight else { return .wait }
        return holder == .outOfSight ? .adopt : .start
    }

    // MARK: Where a paused page had got to

    /// A page's session as it was when it was paused — see `CanvasLinkNodeView.resumeState`.
    struct Resume {
        var state: Any?
        var url: URL?
    }

    /// Kept here rather than on the view, for the same reason the page is: a page frozen on the canvas
    /// and woken in a workspace is one page, and it should come back where you left it rather than at
    /// the address. Keyed by `key(canvas:card:)`; a card forgets its entry when its address changes.
    static var resumes: [String: Resume] = [:]

    /// Running pages waiting for a card that is about to be built — a popup moved onto the board, which
    /// has to keep its renderer (and with it `window.opener`) rather than load its address again. Put
    /// here before the card is added and taken by it as it is built. Keyed by `key(canvas:card:)`.
    static var parked: [String: WKWebView] = [:]

    /// One card, whichever board it is on: the canvas file and the card's id in it.
    static func key(canvas: URL, card: String) -> String {
        canvas.standardizedFileURL.path + "#" + card
    }
}
