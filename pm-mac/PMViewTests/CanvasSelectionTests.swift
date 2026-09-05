import XCTest
import PmLib
@testable import PMViewTests

/// Reading a point on the board, and what a sweep or a drag takes with it.
///
/// These are the interaction rules, asserted directly rather than through a window: the hit tester is
/// a value that takes a document, a zoom and a mode and answers what's under a point, so the awkward
/// cases — a card inside a frame, a grip at 30% zoom, a line running under a card — can each be one
/// assertion instead of a scripted click.
final class CanvasSelectionTests: XCTestCase {

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CanvasRect {
        CanvasRect(x: x, y: y, width: w, height: h)
    }
    private func at(_ x: Double, _ y: Double) -> CanvasPoint { CanvasPoint(x: x, y: y) }

    /// A frame with a card inside it, a second card overlapping the first, and a line between them.
    private func board() -> CanvasDocument {
        CanvasDocument(
            nodes: [
                CanvasNode(id: "frame",
                           content: .group(label: "Wilbur", background: nil, backgroundStyle: nil),
                           frame: rect(0, 0, 800, 400)),
                CanvasNode(id: "a", content: .text("a"), frame: rect(40, 40, 200, 100)),
                CanvasNode(id: "b", content: .text("b"), frame: rect(200, 80, 200, 100)),
                CanvasNode(id: "far", content: .text("far"), frame: rect(1000, 40, 200, 100)),
            ],
            edges: [CanvasEdge(id: "line", fromNode: "b", fromSide: .right,
                               toNode: "far", toSide: .left)])
    }

    private func tester(scale: Double = 1,
                        mode: CanvasMode = .view,
                        selection: Set<String> = [],
                        hovered: String? = nil) -> CanvasHitTester {
        CanvasHitTester(document: board(), scale: scale, mode: mode,
                        selection: selection, hovered: hovered)
    }

    // MARK: Cards

    func testAClickOnACardsFaceTakesTheCard() {
        XCTAssertEqual(tester().hit(at(60, 60)), .node("a"))
    }

    func testTheCardOnTopWins() {
        // a and b overlap between x=200 and x=240.
        XCTAssertEqual(tester().hit(at(220, 100)), .node("b"), "b is later in the document")
    }

    func testEmptyBoardIsTheBoard() {
        XCTAssertEqual(tester().hit(at(2000, 2000)), .board)
    }

    // MARK: Frames

    /// The rule that makes frames usable: the space inside one is still board, so a marquee can start
    /// there and a click there clears the selection.
    func testTheSpaceInsideAFrameIsStillBoard() {
        XCTAssertEqual(tester().hit(at(600, 300)), .board)
    }

    func testAFrameIsTakenOnItsEdge() {
        XCTAssertEqual(tester().hit(at(600, 2)), .node("frame"))
        XCTAssertEqual(tester().hit(at(0, 200)), .node("frame"))
    }

    func testAFrameIsTakenOnItsLabel() {
        XCTAssertEqual(tester().hit(at(20, -12)), .node("frame"), "the label sits above the frame")
        XCTAssertEqual(tester().hit(at(600, -12)), .board, "but only where the label actually is")
    }

    func testACardInsideAFrameIsStillReachable() {
        XCTAssertEqual(tester().hit(at(60, 60)), .node("a"))
    }

    // MARK: Grips

    func testGripsBelongToTheSelectionOnly() {
        XCTAssertEqual(tester(mode: .edit, selection: ["a"]).hit(at(40, 40)), .handle("a", .topLeft))
        XCTAssertEqual(tester(mode: .edit).hit(at(40, 40)), .node("a"),
                       "unselected: it's just the card")
    }

    func testAGripBeatsTheCardUnderneath() {
        XCTAssertEqual(tester(mode: .edit, selection: ["a"]).hit(at(240, 140)),
                       .handle("a", .bottomRight))
    }

    /// A grip you can drag but cannot see is worse than no grip, so view mode — which draws none —
    /// must not answer with one either.
    func testViewModeOffersNoGripsToDrag() {
        XCTAssertEqual(tester(mode: .view, selection: ["a"]).hit(at(40, 40)), .node("a"),
                       "the corner of a selected card is the card, and dragging it moves it")
        // And with no grip in the way, an overlapping corner belongs to whichever card is actually on
        // top there — which is the point: in view mode the board reads as cards, not as controls.
        XCTAssertEqual(tester(mode: .view, selection: ["a"]).hit(at(240, 140)), .node("b"))
    }

    /// Grips are sized in view points, so zooming out doesn't shrink them away — which is exactly when
    /// a board has the most cards on it and the pointer has the least room.
    func testGripsStayTheSameSizeToThePointerAtAnyZoom() {
        // 20 canvas units from the corner is 6 view points at 30% — inside the 7pt reach.
        XCTAssertEqual(tester(scale: 0.3, mode: .edit, selection: ["a"]).hit(at(60, 60)),
                       .handle("a", .topLeft))
        // The same canvas distance at 100% is 20 view points — well outside it.
        XCTAssertEqual(tester(scale: 1, mode: .edit, selection: ["a"]).hit(at(60, 60)), .node("a"))
    }

    // MARK: Connection dots

    func testDotsAreOnlyThereInEditMode() {
        let point = at(240 + CanvasHitTester.anchorOffset, 90)
        XCTAssertEqual(tester(mode: .edit, selection: ["a"]).hit(point), .anchor("a", .right))
        XCTAssertEqual(tester(mode: .view, selection: ["a"]).hit(point), .node("b"),
                       "in view mode the board is cards and lines and nothing else")
    }

    /// In edit mode the card under the pointer offers its dots without having to be selected first —
    /// otherwise wiring two cards together is click, then drag, for every line.
    func testTheHoveredCardOffersDotsInEditMode() {
        let point = at(40 - CanvasHitTester.anchorOffset, 90)
        XCTAssertEqual(tester(mode: .edit, hovered: "a").hit(point), .anchor("a", .left))
        XCTAssertEqual(tester(mode: .edit).hit(point), .board, "nothing hovered, nothing offered")
    }

    // MARK: Lines

    func testALineIsTakenNearIt() throws {
        // Asked of the curve rather than guessed at: a line between two cards on different rows bows,
        // and a point picked by eye from the anchors' coordinates isn't on it.
        let curve = try XCTUnwrap(canvasRoute(for: board().edges[0], in: board()))
        let mid = curve.point(at: 0.5)
        XCTAssertEqual(tester().hit(mid), .edge("line"))
        XCTAssertEqual(tester().hit(at(mid.x, mid.y + 4)), .edge("line"), "a few points off still counts")
        XCTAssertEqual(tester().hit(at(mid.x, mid.y + 60)), .board, "well off it doesn't")
    }

    func testACardBeatsALineRunningUnderIt() {
        let doc = CanvasDocument(
            nodes: [CanvasNode(id: "a", content: .text("a"), frame: rect(0, 0, 100, 100)),
                    CanvasNode(id: "b", content: .text("b"), frame: rect(600, 0, 100, 100)),
                    CanvasNode(id: "over", content: .text("over"), frame: rect(300, 20, 100, 60))],
            edges: [CanvasEdge(id: "line", fromNode: "a", fromSide: .right, toNode: "b", toSide: .left)])
        let t = CanvasHitTester(document: doc, scale: 1, mode: .view, selection: [], hovered: nil)
        XCTAssertEqual(t.hit(at(350, 50)), .node("over"))
    }

    // MARK: Resizing

    func testAGripMovesOnlyTheEdgesItTouches() {
        let frame = rect(100, 100, 200, 200)
        XCTAssertEqual(CanvasHandle.bottomRight.resize(frame, to: at(400, 500)),
                       rect(100, 100, 300, 400))
        XCTAssertEqual(CanvasHandle.top.resize(frame, to: at(999, 50)),
                       rect(100, 50, 200, 250), "a top grip doesn't move x")
        XCTAssertEqual(CanvasHandle.left.resize(frame, to: at(0, 999)),
                       rect(0, 100, 300, 200), "a left grip doesn't move y")
    }

    /// Dragging a grip through the opposite edge stops at a minimum rather than inverting. A negative
    /// width is a card Obsidian draws as nothing — the file would look fine and the board would have a
    /// hole in it.
    func testACardCannotBeDraggedInsideOut() {
        let frame = rect(100, 100, 200, 200)
        let squashed = CanvasHandle.right.resize(frame, to: at(-500, 200), minimum: 40)
        XCTAssertEqual(squashed.width, 40)
        XCTAssertEqual(squashed.minX, 100)
        XCTAssertGreaterThan(CanvasHandle.top.resize(frame, to: at(200, 9999)).height, 0)
    }

    // MARK: Sweeping and dragging

    func testASweepTakesTheCardsItTouchesAndTheFramesItCovers() {
        let swept = canvasMarqueeSelection(rect(-50, -50, 500, 500), in: board())
        XCTAssertTrue(swept.contains("a"))
        XCTAssertTrue(swept.contains("b"), "touched is enough for a card")
        XCTAssertFalse(swept.contains("frame"), "the frame is only half covered")
        XCTAssertFalse(swept.contains("far"))

        let wide = canvasMarqueeSelection(rect(-50, -50, 2000, 2000), in: board())
        XCTAssertTrue(wide.contains("frame"), "covered wholly, so it comes")
    }

    /// A frame carries what it holds — that is what makes it a group rather than a label. Membership
    /// is worked out at the moment of the drag, because the file records none.
    func testDraggingAFrameCarriesWhatIsWhollyInsideIt() {
        let moving = canvasDragSet(["frame"], in: board())
        XCTAssertEqual(moving, ["frame", "a", "b"])
        XCTAssertFalse(moving.contains("far"))
    }

    func testDraggingACardTakesOnlyThatCard() {
        XCTAssertEqual(canvasDragSet(["a"], in: board()), ["a"])
    }

    // MARK: Colour

    func testObsidiansPresetsAndHexBothRead() {
        XCTAssertEqual(CanvasPalette.color("1"), CanvasPalette.presets[0])
        XCTAssertEqual(CanvasPalette.color("6"), CanvasPalette.presets[5])
        XCTAssertNil(CanvasPalette.color(nil))
        XCTAssertNil(CanvasPalette.color(""))
        XCTAssertNil(CanvasPalette.color("9"), "not a preset, and not hex")

        let teal = CanvasPalette.hex("#3ab7a2")
        XCTAssertEqual(teal?.redComponent ?? 0, 0x3a / 255.0, accuracy: 0.002)
        XCTAssertEqual(CanvasPalette.hex("#fff"), CanvasPalette.hex("#ffffff"))
        XCTAssertEqual(CanvasPalette.hex("3ab7a2"), teal, "the hash is optional")
        XCTAssertNil(CanvasPalette.hex("#nothex"))
    }

    // MARK: What an engaged card hands to the board

    /// A 400×400 card, the size a link card actually is on the one board in the vault that has them.
    private let card = NSRect(x: 0, y: 0, width: 400, height: 400)
    /// The caption strip across the top, which a web card offers as its handle.
    private let caption = NSRect(x: 0, y: 0, width: 400, height: 20)

    func testTheMiddleOfAnEngagedCardBelongsToTheCard() {
        XCTAssertFalse(canvasBoardKeeps(NSPoint(x: 200, y: 200), in: card, handle: caption, scale: 1))
    }

    func testTheBorderBelongsToTheBoard() {
        for point in [NSPoint(x: 3, y: 200), NSPoint(x: 397, y: 200), NSPoint(x: 200, y: 397)] {
            XCTAssertTrue(canvasBoardKeeps(point, in: card, handle: caption, scale: 1),
                          "\(point) is within a grip's reach of the edge")
        }
        XCTAssertFalse(canvasBoardKeeps(NSPoint(x: 11, y: 200), in: card, handle: caption, scale: 1),
                       "past the band, and the page's business")
    }

    func testTheCaptionBelongsToTheBoard() {
        XCTAssertTrue(canvasBoardKeeps(NSPoint(x: 200, y: 10), in: card, handle: caption, scale: 1))
        XCTAssertFalse(canvasBoardKeeps(NSPoint(x: 200, y: 30), in: card, handle: caption, scale: 1),
                       "just under it is the page")
    }

    func testACardWithNoHandleGivesUpOnlyItsBorder() {
        XCTAssertFalse(canvasBoardKeeps(NSPoint(x: 200, y: 10), in: card, handle: nil, scale: 1),
                       "a text card has no caption to drag it by")
    }

    /// The band is a pointer's width on screen, so in card points it has to grow as you zoom out —
    /// otherwise the one thing you can still grab shrinks exactly when the cards get small.
    func testTheBorderStaysThickToThePointerAsYouZoomOut() {
        XCTAssertTrue(canvasBoardKeeps(NSPoint(x: 15, y: 200), in: card, handle: nil, scale: 0.3),
                       "15 points in is 4.5 on screen at 30%")
        XCTAssertFalse(canvasBoardKeeps(NSPoint(x: 30, y: 200), in: card, handle: nil, scale: 0.3))
    }

    func testACardTooSmallToSpareItsBorderKeepsAllOfIt() {
        // At 8% the band alone would be 88 points on each side of a 120pt card — the whole card.
        let small = NSRect(x: 0, y: 0, width: 120, height: 120)
        XCTAssertFalse(canvasBoardKeeps(NSPoint(x: 60, y: 60), in: small, handle: nil, scale: 0.08))
    }
}
