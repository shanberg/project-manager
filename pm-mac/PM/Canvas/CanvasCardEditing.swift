import Foundation
import PmLib

/// What a card knows while you are typing in it.
///
/// Three questions, none of them about views, all of them previously loose properties on
/// `CanvasTextNodeView` — which is a class that cannot be built without a board, a window and a
/// document, so none of them could be asked in a test:
///
/// - **Is this change mine?** The editor writes every keystroke into the document, the document tells
///   the board, and the board hands the card back the text it just wrote. Rebuilding the editor there
///   is rebuilding the view the keystroke was typed into — the caret goes to the end of the note and a
///   keystroke that lands before the new view takes focus is beeped away and lost. See `echoes`.
/// - **Is this the first keystroke?** A session is one step on the document's stack, and that step is
///   the *first* keystroke — see `hasWritten`. Everything after it is quiet, because while the editor
///   is open ⌘Z is the editor's own.
/// - **Was this ever a card?** A card you opened empty and left empty was a double-click that landed
///   somewhere you didn't mean, and taking it away again is what Obsidian does too.
struct CanvasCardEditing: Equatable {
    /// The text the card held when you stepped into it — what one ⌘Z after you step out goes back to.
    let opening: String

    /// The last text the editor wrote into the document, since the editor was built.
    ///
    /// Cleared by a rebuild rather than carried across one: what is on screen after a rebuild came
    /// from the document, so there is nothing outstanding for the document to be echoing.
    private var written: String?

    /// Whether this session has changed the document yet.
    ///
    /// **The session's one undo step is its first keystroke, not its last.** A stack is chronological,
    /// and a step registered on the way out would sit above anything that happened while you were
    /// typing — a card moved by its edge, an edit from another window. Undoing *that* would then
    /// restore the document as it stood with your typing in it, handing back text the ⌘Z before it had
    /// just taken away. Registered on the way in, the step is where it belongs: undo the move first,
    /// then undo the typing. Everything after the first keystroke is quiet.
    private(set) var hasWritten = false

    init(opening: String) { self.opening = opening }

    /// The editor wrote this into the document. Called before the change is made, because the store
    /// tells its watchers inside `change` and the answer has to be in place when it comes back.
    mutating func wrote(_ text: String) {
        written = text
        hasWritten = true
    }

    /// A new editor was built for this card — by an outside edit, or by stepping in.
    mutating func editorBuilt() { written = nil }

    /// Whether content arriving from the document is this session's own write, coming back.
    func echoes(_ content: CanvasContent) -> Bool {
        guard case .text(let value) = content else { return false }
        return value == written
    }

    /// What stepping out of the card should do to the document, given what the card says now.
    ///
    /// Nothing about the undo stack: that was settled by the first keystroke. All that is left is
    /// whether the card should be there at all.
    func stepOut(showing text: String) -> Outcome {
        func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return blank(text) && blank(opening) ? .discardTheCard : .keepTheCard
    }

    enum Outcome: Equatable {
        /// Opened empty, left empty: take the card away again.
        ///
        /// Only when it was *already* empty on the way in. A card whose text you deliberately cleared
        /// is a card you emptied, and deleting it would take with it something ⌘Z can no longer bring
        /// back — the edit that emptied it would restore the text into a card that no longer exists.
        case discardTheCard
        /// It has words in it, or it had words in it. It stays.
        case keepTheCard
    }
}
