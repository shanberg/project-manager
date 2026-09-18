import XCTest

/// Where ⌘Z goes on a board. See `CanvasUndoRoute`.
final class CanvasUndoRouteTests: XCTestCase {

    /// The case that lost notes: a session note open on a project card whose history has a step on it
    /// — as it always does once the note has saved once. ⌘Z is the note's.
    func testAnOpenEditorWinsOverAProjectWithHistory() {
        XCTAssertEqual(CanvasUndoRoute.route(editorOpen: true, projectCanAct: true), .editor)
    }

    /// And stays the note's with nothing left on its own stack, rather than reaching past it.
    func testAnOpenEditorWinsEvenWithNothingToUndo() {
        XCTAssertEqual(CanvasUndoRoute.route(editorOpen: true, projectCanAct: false), .editor)
    }

    func testWithNoEditorTheProjectEditedLastComesBeforeTheBoard() {
        XCTAssertEqual(CanvasUndoRoute.route(editorOpen: false, projectCanAct: true), .project)
        XCTAssertEqual(CanvasUndoRoute.route(editorOpen: false, projectCanAct: false), .board)
    }
}
