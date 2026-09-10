import XCTest
import AppKit
import PmLib

/// **What a board is made of halfway between being a board and being a workspace.**
///
/// Crossing into a workspace changes four drawn things at once — the ground, the hairline round every
/// card, the corners it is drawn with, and the shadow it casts — and all four used to change in the
/// frame the mode did, while the cards were still flying to their tile positions. `CanvasBoardView`
/// draws every one of them against `tiledness` now, a number between 0 and 1.
///
/// The arithmetic is what these pin, because it is the half that can be wrong without looking wrong: a
/// blend that quietly resolves a dynamic colour, or one that drops an alpha, gives a board that is
/// subtly the wrong grey and a hairline that is subtly too dark — and the first of those does not even
/// show up during the crossing, it shows up the next time the appearance changes. The motion itself is
/// a thing to look at, and there is nothing to assert about it that is not better said by looking.
@MainActor
final class CanvasCrossingTests: XCTestCase {

    private let light = NSAppearance(named: .aqua)!
    private let dark = NSAppearance(named: .darkAqua)!

    // MARK: The ground

    /// The two ends are the colours themselves, not blends of one part — a board that is not crossing
    /// is exactly the board it was before any of this existed.
    func testTheEndsOfTheCrossingAreTheRealGrounds() {
        XCTAssertEqual(CanvasPalette.ground(tiled: 0), CanvasPalette.board)
        XCTAssertEqual(CanvasPalette.ground(tiled: 1), CanvasPalette.tileGround)
    }

    /// Halfway is between the two, in both appearances, and nearer the tile end at three quarters.
    func testTheGroundDarkensAcrossTheCrossing() {
        for appearance in [light, dark] {
            let board = white(CanvasPalette.board, in: appearance)
            let tiled = white(CanvasPalette.tileGround, in: appearance)
            let half = white(CanvasPalette.ground(tiled: 0.5), in: appearance)
            let most = white(CanvasPalette.ground(tiled: 0.75), in: appearance)
            XCTAssertEqual(half, (board + tiled) / 2, accuracy: 0.002,
                           "halfway across is not halfway between the two grounds")
            XCTAssertLessThan(abs(most - tiled), abs(half - tiled),
                              "three quarters across is not nearer the tiled ground than half")
        }
    }

    /// **The one that would not look like a bug.** `board` is `windowBackgroundColor`, so it answers
    /// differently in the two appearances; a blend made eagerly resolves it once, against whichever
    /// appearance happened to be current when the crossing started, and hands back a constant. The
    /// window would then keep that constant — a board that had stopped following Dark Mode, with
    /// nothing to connect it to except having once made a workspace.
    func testAGroundCaughtMidCrossingStillFollowsTheAppearance() {
        let middle = CanvasPalette.ground(tiled: 0.5)
        XCTAssertNotEqual(white(middle, in: light), white(middle, in: dark), accuracy: 0.2,
                          "a half-crossed ground resolves to the same grey in both appearances — it "
                              + "has been blended eagerly and is no longer dynamic")
        // And it is on the right side of the line in each: light greys light, dark greys dark.
        XCTAssertGreaterThan(white(middle, in: light), 0.5)
        XCTAssertLessThan(white(middle, in: dark), 0.5)
    }

    // MARK: The hairline

    /// A card's hairline is a dark line at 0.1 alpha and a tile's is one at 0.017, so what crosses
    /// between them is mostly *alpha* — and this pins that it survives the crossing, because a mix that
    /// dropped it would draw the quietest line in the app at full strength for a third of a second.
    ///
    /// `blended(withFraction:of:)` does carry alpha through. That is measured rather than assumed: the
    /// name suggests compositing, the documentation says only "a weighted sum of the component values",
    /// and the two readings differ by exactly this test.
    func testTheHairlineKeepsItsAlphaAcrossTheCrossing() {
        let card = CanvasPalette.cardBorder
        let tile = CanvasPalette.tileBorder
        for appearance in [light, dark] {
            let from = alpha(card, in: appearance)
            let to = alpha(tile, in: appearance)
            let half = alpha(CanvasPalette.hairline(card: card, tile: tile, at: 0.5), in: appearance)
            XCTAssertEqual(half, (from + to) / 2, accuracy: 0.002,
                           "the hairline's alpha is no longer halfway between the two — whatever "
                               + "mixes these has stopped carrying alpha through")
            XCTAssertLessThan(half, 0.5, "a hairline at half strength should be nowhere near opaque")
        }
    }

    /// And the hairline has the same dynamic-colour hazard the ground has, for the same reason: these
    /// two are a dark line on a light board and a light one on a dark board, so a blend made eagerly
    /// would leave every card wearing the wrong appearance's edge until the next crossing.
    func testAHairlineCaughtMidCrossingStillFollowsTheAppearance() {
        let middle = CanvasPalette.hairline(card: CanvasPalette.cardBorder,
                                            tile: CanvasPalette.tileBorder, at: 0.5)
        XCTAssertNotEqual(white(middle, in: light), white(middle, in: dark), accuracy: 0.2,
                          "a half-crossed hairline resolves to the same colour in both appearances — "
                              + "it has been blended eagerly and is no longer dynamic")
    }

    func testTheEndsOfTheHairlineAreTheRealColours() {
        let card = CanvasPalette.cardBorder
        let tile = CanvasPalette.tileBorderKey
        XCTAssertEqual(CanvasPalette.hairline(card: card, tile: tile, at: 0), card)
        XCTAssertEqual(CanvasPalette.hairline(card: card, tile: tile, at: 1), tile)
    }

    // MARK: The corners

    /// A card has one radius and a tile has up to two — soft where it meets the frame, tight where it
    /// meets another tile — so the four corners do not all travel to the same number, and mixing them
    /// as a single radius would round the seams of a tiling that is nearly landed.
    func testEachCornerCrossesToItsOwnRadius() {
        let card = CanvasTiling.Radii.uniform(10)
        let tile = CanvasTiling.Radii(topLeft: 12, topRight: 2, bottomRight: 2, bottomLeft: 12)
        let half = CanvasTiling.Radii.mix(card, tile, at: 0.5)
        XCTAssertEqual(half.topLeft, 11, accuracy: 0.001)
        XCTAssertEqual(half.topRight, 6, accuracy: 0.001)
        XCTAssertEqual(half.bottomRight, 6, accuracy: 0.001)
        XCTAssertEqual(half.bottomLeft, 11, accuracy: 0.001)
        XCTAssertFalse(half.isUniform,
                       "a card halfway to being a tile has stopped being one radius, and the drawing "
                           + "path it takes turns on exactly that")
    }

    func testTheEndsOfTheCornersAreTheRealRadii() {
        let card = CanvasTiling.Radii.uniform(10)
        let tile = CanvasTiling.Radii(topLeft: 12, topRight: 2, bottomRight: 2, bottomLeft: 12)
        XCTAssertEqual(CanvasTiling.Radii.mix(card, tile, at: 0), card)
        XCTAssertEqual(CanvasTiling.Radii.mix(card, tile, at: 1), tile)
    }

    // MARK: Where the window has to be looking

    /// **The bug this pins, in one line: the middle of the tiles is not the middle of the window.**
    ///
    /// Entering a workspace measures the area for the zoom it is about to travel to, and then flies the
    /// board there. Flown to the area's own centre, every tiling landed half the header clearance too
    /// high and half the sidebar too far left — visible immediately, and self-correcting on the next
    /// window resize, which is the combination that makes a bug like this hard to place.
    func testTheWindowFramesATilingWhereItWasMeasured() {
        let margins = CanvasTiling.Margins(leading: 260, trailing: 0, top: 40)
        let visible = CanvasRect(x: -300, y: 120, width: 1600, height: 900)
        let area = CanvasTiling.area(of: visible, margins: margins)
        let centre = CanvasTiling.centre(framing: area, margins: margins)
        XCTAssertEqual(centre.x, visible.midX, accuracy: 0.001,
                       "the window is not looking where it was when the tiles were measured")
        XCTAssertEqual(centre.y, visible.midY, accuracy: 0.001,
                       "the window is not looking where it was when the tiles were measured")
        // And the area really is off-centre, so the round trip above is doing work rather than
        // agreeing with itself about nothing.
        XCTAssertEqual(area.midX - visible.midX, 130, accuracy: 0.001)
        XCTAssertEqual(area.midY - visible.midY, 20, accuracy: 0.001)
    }

    /// True at any zoom, which is the case that made it wrong: the margins are view points divided by
    /// the zoom, so at 50% the sidebar is worth twice as many canvas points and the misplacement
    /// doubles with it.
    func testTheFramingHoldsAtEveryZoom() {
        let visible = CanvasRect(x: 40, y: -80, width: 1200, height: 800)
        for zoom in [0.25, 0.5, 1.0, 2.5] {
            let margins = CanvasTiling.Margins(leading: 260 / zoom, trailing: 12 / zoom, top: 40 / zoom)
            let area = CanvasTiling.area(of: visible, margins: margins)
            let centre = CanvasTiling.centre(framing: area, margins: margins)
            XCTAssertEqual(centre.x, visible.midX, accuracy: 0.001, "off at \(zoom)")
            XCTAssertEqual(centre.y, visible.midY, accuracy: 0.001, "off at \(zoom)")
        }
    }

    /// With nothing in the way the two are simply the same point — the case that would have hidden the
    /// bug had the tests been written against a window with no sidebar and no header.
    func testWithNoMarginsTheAreaIsTheWindow() {
        let visible = CanvasRect(x: 0, y: 0, width: 900, height: 600)
        let area = CanvasTiling.area(of: visible, margins: CanvasTiling.Margins())
        XCTAssertEqual(area, visible)
        let centre = CanvasTiling.centre(framing: area, margins: CanvasTiling.Margins())
        XCTAssertEqual(centre.x, visible.midX, accuracy: 0.001)
        XCTAssertEqual(centre.y, visible.midY, accuracy: 0.001)
    }

    // MARK: Reading a colour as it actually is

    /// What `NSColor.resolved(in:)` is for, stated as a test: a dynamic colour asked for its components
    /// answers for whatever appearance is current, which inside a colour block is not the appearance
    /// the block was called for.
    func testResolvingReadsTheAppearanceItWasAskedFor() {
        let dynamic = NSColor(name: nil) { $0.isDark ? .black : .white }
        XCTAssertEqual(white(dynamic, in: light), 1, accuracy: 0.001)
        XCTAssertEqual(white(dynamic, in: dark), 0, accuracy: 0.001)
    }

    // MARK: Reading colours

    private func white(_ color: NSColor, in appearance: NSAppearance) -> CGFloat {
        color.resolved(in: appearance).brightnessComponent
    }

    private func alpha(_ color: NSColor, in appearance: NSAppearance) -> CGFloat {
        color.resolved(in: appearance).alphaComponent
    }
}
