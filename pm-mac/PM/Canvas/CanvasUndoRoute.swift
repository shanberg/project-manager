/// Which of a board's histories ⌘Z and ⇧⌘Z act on.
///
/// A board window answers `undo:` itself, on the pane, because it holds more than one document and
/// the window can only hand back one `UndoManager` — see `CanvasPaneController.undo(_:)`. And since a
/// text view doesn't answer `undo:` either, the key reaches the pane even while you are typing. So the
/// order is the whole decision, and it lives here, where it can be tested without a board:
///
/// 1. **The editor you are typing in**, whenever one is open — a text card, or a session note on a
///    project card. It wins even with nothing left to undo, the way every text field on the Mac does:
///    ⌘Z past the start of your typing does nothing, rather than reaching out of the field and taking
///    back something else. Getting this wrong is what lost notes: a session note's ⌘Z went to the
///    project, which restored the whole file to before the note's last save.
/// 2. **The project edited last**, when it has a step to take — you tick a task and ⌘Z brings the
///    tick back, not the card you nudged before it.
/// 3. **The board.**
///
/// The Edit menu's title and the key's action both come from this, so the menu can't say one thing
/// while the key does another.
enum CanvasUndoRoute: Equatable {
    case editor
    case project
    case board

    static func route(editorOpen: Bool, projectCanAct: Bool) -> CanvasUndoRoute {
        if editorOpen { return .editor }
        if projectCanAct { return .project }
        return .board
    }
}
