import XCTest
import AppKit
import PmLib

/// A link dragged onto a canvas: read off the pasteboard the way the board reads it, and dragged out of
/// a text card's editor, written onto the drag pasteboard the way the editor writes it.
///
/// The board itself isn't in this bundle, so its half is asserted where it is decided: `accept` makes
/// one link card per address `canvasLinks` answers with, and nothing else for a pasteboard it
/// answers empty for. The editor's half is `writeSelection(to:types:)` — the call both a drag and a copy
/// make — handed the drag pasteboard, which is what separates the two. Nothing here writes to the
/// user's clipboard; `tearDown` checks.
@MainActor
final class CanvasLinkDropTests: XCTestCase {

    private var generalChangeCount = 0

    override func setUp() {
        super.setUp()
        generalChangeCount = NSPasteboard.general.changeCount
    }

    override func tearDown() {
        XCTAssertEqual(NSPasteboard.general.changeCount, generalChangeCount,
                       "these tests must not write to the user's clipboard")
        super.tearDown()
    }

    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        addTeardownBlock { board.releaseGlobally() }
        return board
    }

    // MARK: What the board reads

    /// What WebKit puts down for a link dragged out of a page: the address, its name, and the address
    /// again as text.
    func testABrowsersLinkDragIsOneLink() {
        let board = pasteboard()
        board.declareTypes([.URL, .urlName, .string], owner: nil)
        board.setString("https://x.dev/a", forType: .URL)
        board.setString("The A page", forType: .urlName)
        board.setString("https://x.dev/a", forType: .string)
        XCTAssertEqual(canvasLinks(on: board).map(\.address), ["https://x.dev/a"])
        // And the name beside it, which is what the card is called before it has loaded anything.
        XCTAssertEqual(canvasLinks(on: board).map(\.name), ["The A page"])
    }

    /// The case that used to be accepted by the board and then produce nothing.
    func testALinkWithNoTextIsStillALink() {
        let board = pasteboard()
        board.writeObjects([URL(string: "https://x.dev/a")! as NSURL])
        XCTAssertNil(board.string(forType: .string), "the premise: no text flavour at all")
        XCTAssertEqual(canvasLinks(on: board).map(\.address), ["https://x.dev/a"])
    }

    func testSeveralLinksAreSeveralCards() {
        let board = pasteboard()
        board.writeObjects([URL(string: "https://x.dev/a")! as NSURL, URL(string: "https://y.dev/b")! as NSURL])
        XCTAssertEqual(canvasLinks(on: board).map(\.address), ["https://x.dev/a", "https://y.dev/b"])
    }

    func testAMarkdownLinkCopiedAsTextIsALink() {
        let board = pasteboard()
        board.setString("  [the docs](https://x.dev/docs)\n", forType: .string)
        XCTAssertEqual(canvasLinks(on: board).map(\.address), ["https://x.dev/docs"])
    }

    func testProseWithALinkInItIsProse() {
        let board = pasteboard()
        board.setString("see [the docs](https://x.dev/docs) for more", forType: .string)
        XCTAssertEqual(canvasLinks(on: board).map(\.address), [])
    }

    /// A file is the board's to read as a file, before it ever asks about links.
    func testAFileIsNotALink() {
        let board = pasteboard()
        board.writeObjects([URL(fileURLWithPath: "/tmp/a.md") as NSURL])
        XCTAssertEqual(canvasLinks(on: board).map(\.address), [])
    }

    // MARK: What the editor writes

    private let note = "see [the docs](https://x.dev/docs) or https://x.dev/home, or [a note](../a.md)"

    private func editor(selecting fragment: String) -> NoteEditor {
        let editor = NoteEditor()
        editor.reset(note)
        let range = (note as NSString).range(of: fragment)
        XCTAssertNotEqual(range.location, NSNotFound, "the fixture holds \(fragment)")
        editor.view.setSelectedRange(range)
        return editor
    }

    /// Write the selection the way a drag does: the view's own types declared on the drag pasteboard,
    /// then the selection written into them.
    private func drag(_ editor: NoteEditor) -> NSPasteboard {
        let board = NSPasteboard(name: .drag)
        let types = editor.view.writablePasteboardTypes
        board.declareTypes(types, owner: nil)
        XCTAssertTrue(editor.view.writeSelection(to: board, types: types))
        return board
    }

    func testDraggingAWholeLinkCarriesTheLink() {
        let board = drag(editor(selecting: "[the docs](https://x.dev/docs)"))
        XCTAssertEqual(board.string(forType: .URL), "https://x.dev/docs")
        XCTAssertEqual(board.string(forType: .urlName), "the docs")
        XCTAssertEqual(board.string(forType: .string), "[the docs](https://x.dev/docs)",
                       "the text is still the markdown, for a drop into another note")
        XCTAssertEqual(canvasLinks(on: board).map(\.address), ["https://x.dev/docs"])
    }

    /// What you can see of a link while its syntax is hidden, and so what a drag across it selects.
    func testDraggingItsLabelCarriesTheLink() {
        let board = drag(editor(selecting: "the docs"))
        XCTAssertEqual(board.string(forType: .URL), "https://x.dev/docs")
        XCTAssertEqual(canvasLinks(on: board).map(\.address), ["https://x.dev/docs"])
    }

    func testDraggingABareAddressCarriesIt() {
        let board = drag(editor(selecting: " https://x.dev/home"))
        XCTAssertEqual(board.string(forType: .URL), "https://x.dev/home")
        XCTAssertEqual(board.string(forType: .urlName), "https://x.dev/home")
        XCTAssertEqual(canvasLinks(on: board).map(\.address), ["https://x.dev/home"])
    }

    func testDraggingPartOfALabelIsText() {
        let board = drag(editor(selecting: "docs"))
        XCTAssertNil(board.string(forType: .URL))
        XCTAssertEqual(canvasLinks(on: board).map(\.address), [])
    }

    func testDraggingProseAroundALinkIsText() {
        let board = drag(editor(selecting: "see [the docs](https://x.dev/docs)"))
        XCTAssertNil(board.string(forType: .URL))
        XCTAssertEqual(canvasLinks(on: board).map(\.address), [])
    }

    func testDraggingALinkToANoteIsText() {
        let board = drag(editor(selecting: "[a note](../a.md)"))
        XCTAssertNil(board.string(forType: .URL))
    }

    /// The real drag, not a stand-in for it: `NSTextView`'s own `dragSelection`, which is what a press
    /// on a selection and a move calls. Asserted because every test above calls `writeSelection`
    /// directly, and that is only worth anything if the drag goes through it.
    func testTheTextViewsOwnDragCarriesTheLink() {
        let editor = editor(selecting: "[the docs](https://x.dev/docs)")
        let view = editor.view
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let glyphs = view.layoutManager!.glyphRange(forCharacterRange: view.selectedRange(),
                                                    actualCharacterRange: nil)
        let rect = view.layoutManager!.boundingRect(forGlyphRange: glyphs, in: view.textContainer!)
        let at = view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: 0,
                               windowNumber: editor.window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // **The drag has to be seen out, here, or it wedges the whole bundle.**
        //
        // `dragSelection` writes the pasteboard — which is everything this test asserts — and then
        // hands off to AppKit, which starts the drag *asynchronously*: the blocking part,
        // `_dragUntilMouseUp:`, is entered from a runloop observer some time later and waits for an
        // up. One posted ahead of the call is usually the event it gets; when it isn't, nothing ever
        // ends that loop. See `seeOutAnyTrackingLoop`, which is where the rest of this is argued.
        NSApp.postEvent(mouse(.leftMouseUp), atStart: true)
        let board = NSPasteboard(name: .drag)
        board.clearContents()
        XCTAssertTrue(view.dragSelection(with: mouse(.leftMouseDown), offset: .zero, slideBack: false))
        XCTAssertEqual(board.string(forType: .URL), "https://x.dev/docs")
        XCTAssertEqual(canvasLinks(on: board).map(\.address), ["https://x.dev/docs"])
        seeOutAnyTrackingLoop(in: editor.window, at: at)
    }

    /// The same selection, copied rather than dragged, stays text — see `writeSelection` for why.
    func testCopyingALinkLeavesItText() {
        let editor = editor(selecting: "[the docs](https://x.dev/docs)")
        let board = pasteboard()
        let types = editor.view.writablePasteboardTypes
        board.declareTypes(types, owner: nil)
        XCTAssertTrue(editor.view.writeSelection(to: board, types: types))
        XCTAssertEqual(board.string(forType: .string), "[the docs](https://x.dev/docs)")
        XCTAssertNil(board.string(forType: .URL))
    }
}
