import XCTest

/// What an open session note does when the file moves underneath it. See `SessionNoteMerge`.
final class SessionNoteMergeTests: XCTestCase {

    private let before = "Morning."
    private let saved = "Morning.\n\nParagraph A."

    /// An undo made elsewhere takes the file back past what the editor last saved, while the editor
    /// has nothing unsaved. It follows the file, so what's on screen is what's on disk.
    func testAnIdleEditorFollowsTheFile() {
        XCTAssertEqual(SessionNoteMerge.adopting(onDisk: before, edited: saved, seed: saved), before)
    }

    /// Unsaved typing is never replaced; the save that follows goes through `resolve`.
    func testAnEditorWithUnsavedTypingKeepsIt() {
        let typing = saved + "\n\nParagraph B."
        XCTAssertNil(SessionNoteMerge.adopting(onDisk: before, edited: typing, seed: saved))
    }

    /// The file coming back to what the editor last wrote — its own save landing — changes nothing.
    func testTheEditorsOwnSaveIsNotAChange() {
        XCTAssertNil(SessionNoteMerge.adopting(onDisk: saved, edited: saved, seed: saved))
    }

    /// Why following matters: without it, the rolled-back file reads to `resolve` as somebody else's
    /// edit, and the paragraph saved before it is dropped from what gets written. This is the loss
    /// itself, pinned so it stays understood — the fix is that the editor no longer gets here by its
    /// own ⌘Z (`CanvasUndoRoute`) and shows a rollback from anywhere else as it happens.
    func testAResolveAgainstARolledBackFileKeepsOnlyTheNewTyping() {
        let typing = saved + "\n\nParagraph B."
        XCTAssertEqual(SessionNoteMerge.resolve(edited: typing, onDisk: before, seed: saved),
                       .merged(before + "\n\nParagraph B."))
    }
}
