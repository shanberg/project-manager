import XCTest
import AppKit
import PmLib

/// What a pasteboard would put on a board, and where — the one reading the card a drag shows on its
/// way in and the card the drop then makes both come from. See `CanvasDrop`.
///
/// Every pasteboard here is this suite's own; `tearDown` checks the user's clipboard was never touched.
@MainActor
final class CanvasDropTests: XCTestCase {

    private var generalChangeCount = 0
    private static let cardsType = NSPasteboard.PasteboardType("com.stuarthanberg.pm.canvas-nodes")

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

    private func read(_ board: NSPasteboard) -> CanvasDrop? {
        CanvasDrop.read(board, cardsType: Self.cardsType)
    }

    // MARK: Reading

    /// A drag the board declines — no preview, no card — rather than one it accepts and does nothing with.
    func testNothingABoardCanHoldIsNothing() {
        XCTAssertNil(read(pasteboard()))
        let blank = pasteboard()
        blank.setString("  \n ", forType: .string)
        XCTAssertNil(read(blank))
    }

    func testAFileIsAFile() {
        let board = pasteboard()
        board.writeObjects([URL(fileURLWithPath: "/tmp/a.md") as NSURL])
        guard case .files(let files)? = read(board) else { return XCTFail("\(String(describing: read(board)))") }
        XCTAssertEqual(files.map(\.lastPathComponent), ["a.md"])
    }

    /// The link a text card's editor drags: markdown for its text, the address beside it.
    func testALinkIsReadBeforeItsText() {
        let board = pasteboard()
        board.declareTypes([.string, .URL], owner: nil)
        board.setString("[the docs](https://x.dev/docs)", forType: .string)
        board.setString("https://x.dev/docs", forType: .URL)
        guard case .links(let links)? = read(board) else { return XCTFail("\(String(describing: read(board)))") }
        XCTAssertEqual(links.map(\.address), ["https://x.dev/docs"])
    }

    /// A browser drops the page's name beside the address, and the card is named by it before it loads.
    func testALinkKeepsTheNameTheBrowserDroppedWithIt() {
        let board = pasteboard()
        board.declareTypes([.URL, .urlName], owner: nil)
        board.setString("https://x.dev/docs", forType: .URL)
        board.setString("The Docs", forType: .urlName)
        guard case .links(let links)? = read(board) else { return XCTFail("\(String(describing: read(board)))") }
        XCTAssertEqual(links.map(\.name), ["The Docs"])
    }

    /// A markdown link copied as words carries its label in the text, and that label is the name.
    func testAMarkdownLinkIsNamedByItsLabel() {
        let board = pasteboard()
        board.setString("[the docs](https://x.dev/docs)", forType: .string)
        guard case .links(let links)? = read(board) else { return XCTFail("\(String(describing: read(board)))") }
        XCTAssertEqual(links.map(\.address), ["https://x.dev/docs"])
        XCTAssertEqual(links.map(\.name), ["the docs"])
    }

    func testWordsAreText() {
        let board = pasteboard()
        board.setString("  see https://x.dev for more\n", forType: .string)
        guard case .text(let text)? = read(board) else { return XCTFail("\(String(describing: read(board)))") }
        XCTAssertEqual(text, "see https://x.dev for more")
    }

    // MARK: Where the cards go

    /// Centred, because the card rides under the pointer on the way in and must not jump on the drop.
    func testACardIsCentredOnThePoint() {
        let at = CanvasPoint(x: 100, y: 100)
        XCTAssertEqual(CanvasDrop.text("x").frames(centredOn: at),
                       [CanvasRect(x: -25, y: 40, width: 250, height: 120)])
        XCTAssertEqual(CanvasDrop.image(data: Data(), ext: "png").frames(centredOn: at),
                       [CanvasRect(x: -100, y: -100, width: 400, height: 400)])
    }

    func testSeveralLinksCascadeFromTheFirst() {
        let links = ["https://a.dev", "https://b.dev"].map { CanvasDroppedLink(address: $0) }
        XCTAssertEqual(CanvasDrop.links(links).frames(centredOn: CanvasPoint(x: 100, y: 100)),
                       [CanvasRect(x: -100, y: -100, width: 400, height: 400),
                        CanvasRect(x: -70, y: -70, width: 400, height: 400)])
    }

    func testAPictureGetsASquareCardAndANoteDoesNot() {
        let files = [URL(fileURLWithPath: "/tmp/shot.png"), URL(fileURLWithPath: "/tmp/a.md")]
        XCTAssertEqual(CanvasDrop.files(files).frames(centredOn: CanvasPoint(x: 0, y: 0)).map(\.height), [400, 300])
    }

    /// Copied cards keep the arrangement they were copied in, moved as one to the point.
    func testCopiedCardsKeepTheirArrangement() {
        let copied = CanvasDocument(nodes: [
            CanvasNode(content: .text("a"), frame: CanvasRect(x: 0, y: 0, width: 100, height: 50)),
            CanvasNode(content: .text("b"), frame: CanvasRect(x: 200, y: 100, width: 100, height: 50)),
        ])
        XCTAssertEqual(CanvasDrop.cards(copied).frames(centredOn: CanvasPoint(x: 1000, y: 1000)),
                       [CanvasRect(x: 850, y: 925, width: 100, height: 50),
                        CanvasRect(x: 1050, y: 1025, width: 100, height: 50)])
    }
}
