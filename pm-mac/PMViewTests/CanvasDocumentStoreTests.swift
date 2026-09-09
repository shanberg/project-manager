import XCTest
import PmLib

/// What ⌘Z means on a canvas: what goes on the stack, what deliberately doesn't, and what one step
/// takes back when several things have happened since.
///
/// Driven through a real store on a real file in a temporary directory, because the undo stack, the
/// change notification and the file on disk are the three things a card's editing session touches and
/// a fake of any of them would be a fake of the thing under test.
@MainActor
final class CanvasDocumentStoreTests: XCTestCase {

    private var url: URL!
    private var store: CanvasDocumentStore!

    private let card = "card-1"
    private let other = "card-2"

    override func setUpWithError() throws {
        try super.setUpWithError()
        let document = CanvasDocument(nodes: [
            CanvasNode(id: card, content: .text("before"),
                       frame: CanvasRect(x: 0, y: 0, width: 200, height: 120)),
            CanvasNode(id: other, content: .text("neighbour"),
                       frame: CanvasRect(x: 400, y: 0, width: 200, height: 120)),
        ])
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-store-tests-\(UUID().uuidString).canvas")
        try document.write(to: url)
        store = try CanvasDocumentStore(url: url)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: url)
        try super.tearDownWithError()
    }

    /// End the turn the last thing happened in.
    ///
    /// `UndoManager` groups by runloop turn — which is what makes a burst of keystrokes one step
    /// rather than twenty — so two things done in one turn are one thing to ⌘Z. A test does nothing
    /// *but* run straight through, so anywhere these tests mean two steps they have to let the turn
    /// between them end. `testUndoingTheTypingLeavesAMoveMadeDuringItAlone` is where that is load
    /// bearing, and it fails without this.
    private func settle() {
        // Through the main queue rather than `RunLoop.run(until:)`, which returns straight away when
        // nothing is attached to the loop — and a turn that never ran is a group that never closed.
        let turn = expectation(description: "the runloop turn ends")
        DispatchQueue.main.async { turn.fulfill() }
        wait(for: [turn], timeout: 1)
    }

    private func text(of id: String) -> String? {
        guard case .text(let value) = store.document.nodes.first(where: { $0.id == id })?.content
        else { return nil }
        return value
    }

    private func frame(of id: String) -> CanvasRect? {
        store.document.nodes.first(where: { $0.id == id })?.frame
    }

    /// An editing session in a card, driven exactly as `CanvasTextNodeView` drives one — through the
    /// real policy type, so this cannot drift from what the card actually does.
    private var session: CanvasCardEditing?

    private func stepInto(_ id: String) {
        session = CanvasCardEditing(opening: text(of: id) ?? "")
    }

    /// One keystroke. The first of a session is the document's one step; every one after it is the
    /// editor's own and goes in quietly. See `CanvasCardEditing.hasWritten`.
    private func type(_ text: String, into id: String) {
        let write = { (doc: inout CanvasDocument) in
            guard let index = doc.nodes.firstIndex(where: { $0.id == id }) else { return }
            doc.nodes[index].content = .text(text)
        }
        let opensTheEdit = session?.hasWritten == false
        session?.wrote(text)
        if opensTheEdit { store.change("Edit Card", write) } else { store.changeQuietly(write) }
    }

    private func move(_ id: String, by dx: Double) {
        store.change("Move Card") { doc in
            guard let index = doc.nodes.firstIndex(where: { $0.id == id }) else { return }
            doc.nodes[index].frame.x += dx
        }
    }

    // MARK: The document's own steps

    func testAChangeIsOneUndoStepThatGoesBackAndForward() {
        move(card, by: 50)
        settle()
        XCTAssertEqual(frame(of: card)?.x, 50)

        store.undoManager.undo()
        XCTAssertEqual(frame(of: card)?.x, 0)

        store.undoManager.redo()
        XCTAssertEqual(frame(of: card)?.x, 50)
    }

    func testAChangeThatChangesNothingIsNotAStep() {
        store.change("Move Card") { _ in }
        settle()
        XCTAssertFalse(store.undoManager.canUndo)
    }

    // MARK: A card's editing session

    /// A hundred keystrokes are not a hundred things to undo. The first one opens the step; the rest
    /// are the editor's own, and while the editor is open ⌘Z is the editor's.
    func testAWholeSessionIsOneStepOnTheDocumentsStack() {
        stepInto(card)
        type("b", into: card)
        type("be", into: card)
        type("bef", into: card)
        settle()

        XCTAssertEqual(store.undoManager.undoActionName, "Edit Card")
        store.undoManager.undo()
        XCTAssertEqual(text(of: card), "before")
        XCTAssertFalse(store.undoManager.canUndo, "the session should have left exactly one step")
    }

    func testRedoPutsTheWholeSessionBack() {
        stepInto(card)
        type("before and after", into: card)
        type("before and after!", into: card)
        settle()

        store.undoManager.undo()
        XCTAssertEqual(text(of: card), "before")
        store.undoManager.redo()
        XCTAssertEqual(text(of: card), "before and after!")
    }

    /// A card you opened, read and stepped out of is not an edit.
    func testACardYouOnlyReadIsNotAStep() {
        stepInto(card)
        settle()
        XCTAssertFalse(store.undoManager.canUndo)
    }

    /// Stepping in again is a second session, and a second step. Two ⌘Z, in the order they were made.
    func testSteppingOutAndBackInIsASecondStep() {
        stepInto(card)
        type("before, once", into: card)
        settle()
        stepInto(card)
        type("before, twice", into: card)
        settle()

        store.undoManager.undo()
        XCTAssertEqual(text(of: card), "before, once")
        store.undoManager.undo()
        XCTAssertEqual(text(of: card), "before")
    }

    /// The reason the step is the session's *first* keystroke rather than its last.
    ///
    /// A card can be moved while you are typing in it, and that move is a step of its own. Undo has to
    /// walk back through the two in the order they happened — the move, then the typing — and neither
    /// step may hand back what the other one took away.
    func testAMoveMadeWhileTypingUndoesInOrder() {
        stepInto(card)
        type("before and after", into: card)
        settle()
        move(card, by: 120)
        settle()

        store.undoManager.undo()
        XCTAssertEqual(frame(of: card)?.x, 0, "the move goes back first")
        XCTAssertEqual(text(of: card), "before and after", "and it must not take the typing with it")

        store.undoManager.undo()
        XCTAssertEqual(text(of: card), "before")
        XCTAssertEqual(frame(of: card)?.x, 0)
    }

    /// Another card edited in the meantime — a second window on the same file — is somebody else's
    /// work, and one card's undo does not reach into it.
    func testUndoingOneCardsEditLeavesAnotherCardsAlone() {
        stepInto(other)
        type("neighbour, edited", into: other)
        settle()
        stepInto(card)
        type("before and after", into: card)
        settle()

        store.undoManager.undo()
        XCTAssertEqual(text(of: card), "before")
        XCTAssertEqual(text(of: other), "neighbour, edited")
    }

    // MARK: What the rest of the app hears

    /// Quiet is about the undo stack and nothing else. The board still has to be told, because that
    /// is how what you typed reaches the card's own view — and the file still has to be written.
    func testAQuietChangeStillReachesTheWatchers() {
        var told = 0
        store.addWatcher(self, changed: { told += 1 }, reloaded: {})
        stepInto(card)
        type("typed", into: card)
        type("typed a bit more", into: card)
        XCTAssertEqual(told, 2, "quiet is about the undo stack and nothing else")
        store.removeWatcher(self)
    }

    func testTheFileMatchesTheBoardAfterSaving() throws {
        stepInto(card)
        type("written to disk", into: card)
        settle()
        store.save()

        let reread = try CanvasDocument.read(contentsOf: url)
        guard case .text(let value) = reread.nodes.first(where: { $0.id == card })?.content else {
            return XCTFail("the card should still be a text card")
        }
        XCTAssertEqual(value, "written to disk")
    }

    /// Undo is a change like any other as far as the file is concerned: what is on the board is what
    /// gets written.
    func testUndoIsSavedToo() throws {
        stepInto(card)
        type("written to disk", into: card)
        settle()
        store.undoManager.undo()
        store.save()

        let reread = try CanvasDocument.read(contentsOf: url)
        guard case .text(let value) = reread.nodes.first(where: { $0.id == card })?.content else {
            return XCTFail("the card should still be a text card")
        }
        XCTAssertEqual(value, "before")
    }
}
