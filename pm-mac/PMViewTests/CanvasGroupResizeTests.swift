import XCTest
import PmLib
@testable import PMViewTests

/// Resizing several cards by the box around them.
///
/// The rule being asserted throughout is the one that isn't obvious: the **gaps hold their length**
/// and the cards absorb the change. Every case here is one where naive proportional scaling gives a
/// different answer, and the difference is exactly the tidying-up you would otherwise do by hand
/// afterwards.
final class CanvasGroupResizeTests: XCTestCase {

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CanvasRect {
        CanvasRect(x: x, y: y, width: w, height: h)
    }

    private func resize(_ frames: [String: CanvasRect],
                        to target: CanvasRect) -> [String: CanvasRect] {
        let box = frames.values.dropFirst().reduce(frames.values.first!) { $0.union($1) }
        return CanvasGroupResize.frames(frames, from: box, to: target)
    }

    // MARK: One card

    /// The single-card path goes through the same arithmetic — two edges, one run, no gaps — so a
    /// plain resize is the degenerate case rather than a branch of its own.
    func testOneCardIsJustAResize() {
        let out = resize(["a": rect(100, 100, 200, 100)], to: rect(100, 100, 400, 300))
        XCTAssertEqual(out["a"], rect(100, 100, 400, 300))
    }

    func testOneCardFollowsAnEdgeThatMovedBackwards() {
        // The box's left edge dragged left: the card grows leftwards and its right edge stays.
        let out = resize(["a": rect(100, 0, 200, 100)], to: rect(40, 0, 260, 100))
        XCTAssertEqual(out["a"], rect(40, 0, 260, 100))
    }

    // MARK: The gap is held

    /// Two cards side by side with a 20pt gap. Double the box's width and the gap is still 20pt — the
    /// two cards share every point of the growth between them.
    func testTheGapBetweenTwoCardsSurvivesAWiderBox() {
        let frames = ["a": rect(0, 0, 100, 50), "b": rect(120, 0, 100, 50)]
        // 220 wide, of which 200 is card and 20 is gap. Ask for 420: the cards get 400, so ×2 each.
        let out = resize(frames, to: rect(0, 0, 420, 50))

        XCTAssertEqual(out["a"], rect(0, 0, 200, 50))
        XCTAssertEqual(out["b"], rect(220, 0, 200, 50))
        XCTAssertEqual(out["b"]!.minX - out["a"]!.maxX, 20, "the gap did not stretch")
    }

    /// The same box under proportional scaling would have put the gap at 40 — this is the case the
    /// whole file exists for, stated as the comparison.
    func testProportionalScalingWouldHaveStretchedTheGap() {
        let frames = ["a": rect(0, 0, 100, 50), "b": rect(120, 0, 100, 50)]
        let out = resize(frames, to: rect(0, 0, 440, 50))
        let proportional = 20.0 * (440.0 / 220.0)
        XCTAssertEqual(proportional, 40)
        XCTAssertEqual(out["b"]!.minX - out["a"]!.maxX, 20, "held, not scaled to \(proportional)")
    }

    /// Shrinking is the same rule run the other way: the gap is still 20 and the cards give up the
    /// difference.
    func testTheGapSurvivesANarrowerBoxToo() {
        let frames = ["a": rect(0, 0, 100, 50), "b": rect(120, 0, 100, 50)]
        let out = resize(frames, to: rect(0, 0, 120, 50))
        XCTAssertEqual(out["a"], rect(0, 0, 50, 50))
        XCTAssertEqual(out["b"], rect(70, 0, 50, 50))
        XCTAssertEqual(out["b"]!.minX - out["a"]!.maxX, 20)
    }

    /// Several gaps of different sizes each keep their own length, rather than all being averaged or
    /// all being scaled.
    func testEveryGapKeepsItsOwnLength() {
        let frames = ["a": rect(0, 0, 100, 50),
                      "b": rect(110, 0, 100, 50),   // 10pt gap
                      "c": rect(260, 0, 100, 50)]   // 50pt gap
        let out = resize(frames, to: rect(0, 0, 660, 50))
        XCTAssertEqual(out["b"]!.minX - out["a"]!.maxX, 10)
        XCTAssertEqual(out["c"]!.minX - out["b"]!.maxX, 50)
        // 360 wide, 300 of it card. Asking for 660 leaves 600 for the cards: ×2.
        XCTAssertEqual(out["a"]!.width, 200)
        XCTAssertEqual(out["c"]!.width, 200)
    }

    // MARK: Both axes, and the shapes a board actually has

    func testTheTwoAxesAreIndependent() {
        let frames = ["a": rect(0, 0, 100, 50), "b": rect(120, 200, 100, 50)]
        // Wider by 100, and the same height.
        let out = resize(frames, to: rect(0, 0, 320, 250))
        XCTAssertEqual(out["b"]!.minX - out["a"]!.maxX, 20, "the horizontal gap held")
        XCTAssertEqual(out["b"]!.minY - out["a"]!.maxY, 150, "the vertical gap held, untouched")
        XCTAssertEqual(out["a"]!.height, 50, "nothing changed on an axis that didn't move")
    }

    /// Two cards flush against each other stay flush. They share a coordinate, so they share a break,
    /// and neither can drift a fraction of a point away from the other.
    func testCardsThatWereFlushStayFlush() {
        let frames = ["a": rect(0, 0, 100, 50), "b": rect(100, 0, 33, 50)]
        let out = resize(frames, to: rect(0, 0, 400, 50))
        XCTAssertEqual(out["a"]!.maxX, out["b"]!.minX, accuracy: 0.0001)
    }

    /// Overlapping cards are not a special case — the runs are worked out from the edges themselves,
    /// so an overlap is simply a stretch that two cards both cover.
    func testOverlappingCardsScaleTogether() {
        let frames = ["a": rect(0, 0, 100, 50), "b": rect(50, 0, 100, 50)]
        let out = resize(frames, to: rect(0, 0, 300, 50))
        XCTAssertEqual(out["a"]!.width, 200, "no gaps anywhere, so everything doubled")
        XCTAssertEqual(out["b"]!.width, 200)
        XCTAssertEqual(out["b"]!.minX, 100)
    }

    /// A card spanning the whole selection with two others lying on top of it.
    ///
    /// Nothing is held here, and that is the rule rather than a gap in it: what a run has to be to
    /// keep its length is *empty board*, and the space between the two small cards is not empty — it
    /// is the wide card's surface. So the whole selection scales, which is also the only answer that
    /// keeps the small cards where they were on the card they are sitting on. Holding that stretch
    /// would slide them off it.
    func testAStretchLyingOnACardIsNotAGap() {
        let frames = ["wide": rect(0, 0, 300, 200),
                      "a": rect(20, 20, 50, 20),
                      "b": rect(120, 20, 50, 20)]
        let out = resize(frames, to: rect(0, 0, 600, 200))
        XCTAssertEqual(out["wide"]!.minX, 0)
        XCTAssertEqual(out["wide"]!.maxX, 600)
        XCTAssertEqual(out["b"]!.minX - out["a"]!.maxX, 100, "scaled with the card underneath it")
        XCTAssertEqual(out["a"]!.minX, 40, "still a fifth of the way along the wide card")
    }

    /// The same shape with real board between the cards: now the empty stretch holds and only the
    /// cards on either side of it grow.
    func testEmptyBoardBesideAWideCardStillHolds() {
        let frames = ["wide": rect(0, 0, 300, 60), "far": rect(340, 0, 100, 60)]
        // 440 wide: 400 of card, 40 of board. Ask for 840 and the cards get 800 — ×2.
        let out = resize(frames, to: rect(0, 0, 840, 60))
        XCTAssertEqual(out["wide"]!.width, 600)
        XCTAssertEqual(out["far"]!.width, 200)
        XCTAssertEqual(out["far"]!.minX - out["wide"]!.maxX, 40)
    }

    // MARK: Floors

    /// Dragged smaller than its own gaps, the selection stops at the point where its smallest card
    /// would fall under the minimum — rather than producing zero-width or inside-out cards.
    func testNoCardIsCrushedBelowTheMinimum() {
        let frames = ["a": rect(0, 0, 60, 50), "b": rect(200, 0, 900, 50)]
        let out = resize(frames, to: rect(0, 0, 50, 50))
        XCTAssertGreaterThanOrEqual(out["a"]!.width, CanvasGroupResize.minimum)
        XCTAssertGreaterThan(out["b"]!.width, 0)
    }

    func testTheBoxCanBeDraggedPastTheGapsWithoutInverting() {
        let frames = ["a": rect(0, 0, 100, 50), "b": rect(500, 0, 100, 50)]
        // Asking for less than the 400pt gap alone.
        let out = resize(frames, to: rect(0, 0, 100, 50))
        for frame in out.values {
            XCTAssertGreaterThan(frame.width, 0, "never inside out")
        }
    }

    /// A selection that is flat on one axis — two cards side by side at the same height — has a
    /// zero-length box there. It must come back unchanged rather than as a division by zero.
    func testAFlatAxisIsLeftAlone() {
        let frames = ["a": rect(0, 100, 100, 0), "b": rect(200, 100, 100, 0)]
        let out = resize(frames, to: rect(0, 100, 400, 0))
        XCTAssertEqual(out["a"]!.minY, 100)
        XCTAssertEqual(out["b"]!.minY, 100)
        XCTAssertFalse(out.values.contains { $0.width.isNaN || $0.minY.isNaN })
    }

    // MARK: Moving the box rather than sizing it

    /// A box moved without changing size takes everything with it, spacing intact — the identity case,
    /// and the one that would show up immediately as drift if the map had an off-by-one in it.
    func testATranslatedBoxMovesEverythingUntouched() {
        let frames = ["a": rect(0, 0, 100, 50), "b": rect(120, 30, 80, 90)]
        let out = resize(frames, to: rect(1000, 500, 200, 120))
        XCTAssertEqual(out["a"], rect(1000, 500, 100, 50))
        XCTAssertEqual(out["b"], rect(1120, 530, 80, 90))
    }
}
