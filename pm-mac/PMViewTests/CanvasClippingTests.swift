import AppKit
import PmLib
import XCTest

/// What leaves a board when you copy.
///
/// Both rules here have a wrong answer that is invisible at the moment it is made and shows up only
/// when somebody pastes — an edge with one end missing, or a clipping that arrives in a text editor
/// as a column of blank lines. They lived in `CanvasBoardView+Commands` among a hundred and
/// twenty-seven other methods and had no tests; they are decisions about a document and a set of ids,
/// so the move made them assertable.
final class CanvasClippingTests: XCTestCase {

    private func node(_ id: String, _ content: CanvasContent) -> CanvasNode {
        CanvasNode(id: id, content: content, frame: CanvasRect(x: 0, y: 0, width: 100, height: 100))
    }

    private func edge(_ from: String, _ to: String) -> CanvasEdge {
        CanvasEdge(id: "\(from)->\(to)", fromNode: from, toNode: to)
    }

    private var board: CanvasDocument {
        CanvasDocument(nodes: [node("a", .text("first")),
                               node("b", .text("second")),
                               node("c", .link(url: "https://example.com"))],
                       edges: [edge("a", "b"), edge("b", "c")])
    }

    // MARK: The canvas flavour

    func testCopyingCardsCarriesOnlyThoseCards() {
        let clip = CanvasClipping.clipping(of: ["a", "b"], from: board)
        XCTAssertEqual(clip.nodes.map(\.id), ["a", "b"])
    }

    /// **The rule worth a test.** A line to a card you didn't copy has nowhere to land, and the format
    /// has no way to express one — so it is dropped rather than pasted as an edge nothing will draw.
    func testALineIsCarriedOnlyWhenBothItsEndsWereCopied() {
        let clip = CanvasClipping.clipping(of: ["a", "b"], from: board)
        XCTAssertEqual(clip.edges.map(\.id), ["a->b"],
                       "b→c had one end outside the selection and must not come with it")
    }

    func testCopyingOneCardCarriesNoLinesAtAll() {
        XCTAssertTrue(CanvasClipping.clipping(of: ["b"], from: board).edges.isEmpty)
    }

    func testCopyingEverythingCarriesEveryLine() {
        let clip = CanvasClipping.clipping(of: ["a", "b", "c"], from: board)
        XCTAssertEqual(clip.edges.count, 2)
    }

    // MARK: The text flavour

    /// A card copied out of PM has to arrive somewhere else as words. Each kind of card says the thing
    /// it is worth outside a canvas.
    func testEachKindOfCardSaysWhatItIsWorthAsText() {
        let doc = CanvasDocument(nodes: [node("t", .text("some prose")),
                                         node("l", .link(url: "https://example.com")),
                                         node("f", .file(path: "Notes.md", subpath: "#heading")),
                                         node("g", .group(label: "A frame", background: nil, backgroundStyle: nil))])
        let text = CanvasClipping.plainText(of: ["t", "l", "f", "g"], from: doc)
        XCTAssertEqual(text, "some prose\n\nhttps://example.com\n\nNotes.md#heading\n\nA frame")
    }

    /// An unlabelled frame carries nothing, and three of them would otherwise arrive as six newlines.
    func testCardsWithNothingToSayAreLeftOutRatherThanPastedAsBlankLines() {
        let doc = CanvasDocument(nodes: [node("g1", .group(label: nil, background: nil, backgroundStyle: nil)),
                                         node("t", .text("the only words here")),
                                         node("g2", .group(label: "", background: nil, backgroundStyle: nil))])
        XCTAssertEqual(CanvasClipping.plainText(of: ["g1", "t", "g2"], from: doc),
                       "the only words here")
    }

    func testAFileCardWithNoSubpathIsJustItsPath() {
        let doc = CanvasDocument(nodes: [node("f", .file(path: "Projects/W-1 Thing/Notes.md", subpath: nil))])
        XCTAssertEqual(CanvasClipping.plainText(of: ["f"], from: doc),
                       "Projects/W-1 Thing/Notes.md")
    }

    // MARK: Both at once

    /// Anything that can read a canvas gets the canvas; everything else gets the prose. Writing only
    /// one of the two is the failure that makes a copied card useless in the other half of the world.
    func testWritingPutsBothFlavoursDown() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("CanvasClippingTests"))
        CanvasClipping.write(["a", "b"], from: board, to: pasteboard)

        let carried = try XCTUnwrap(pasteboard.data(forType: CanvasClipping.pasteboardType))
        XCTAssertFalse(carried.isEmpty)
        XCTAssertEqual(pasteboard.string(forType: .string), "first\n\nsecond")
    }

    /// And the canvas flavour round-trips, which is the whole reason for having a private type rather
    /// than relying on the text.
    func testTheCanvasFlavourComesBackAsTheSameCards() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("CanvasClippingTests.roundTrip"))
        CanvasClipping.write(["a", "b"], from: board, to: pasteboard)

        let data = try XCTUnwrap(pasteboard.data(forType: CanvasClipping.pasteboardType))
        let back = try CanvasDocument.parse(data)
        XCTAssertEqual(back.nodes.map(\.id), ["a", "b"])
        XCTAssertEqual(back.edges.map(\.id), ["a->b"])
    }
}
