import XCTest
import AppKit
import UniformTypeIdentifiers
import PmLib

/// Dragging a tab chip: what it carries, what the row does with it, and what a board does with a card
/// that turns up in the middle of a workspace it is not part of.
///
/// All three are the one accident — a reorder that strayed off the header and was let go over a
/// workspace — taken apart at the three places it went wrong.
@MainActor
final class TabDragTests: XCTestCase {

    // MARK: What a chip carries

    /// Its own type and nothing else — in particular nothing that is text, which is what a board makes
    /// a card out of.
    func testAChipCarriesOnlyItsOwnType() {
        let provider = ProjectTabDrag.itemProvider(for: "tab-1") {}
        XCTAssertEqual(provider.registeredTypeIdentifiers, [ProjectTabDrag.type.identifier])
        for identifier in provider.registeredTypeIdentifiers {
            XCTAssertFalse(UTType(identifier)?.conforms(to: .text) ?? false, identifier)
        }
    }

    /// A board offered a dragged chip declines it: no preview, and nothing to drop.
    func testABoardDeclinesADraggedChip() {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        defer { board.releaseGlobally() }
        board.setData(Data("0F9C1A2B-3D4E-4F50-8A6B-7C8D9E0F1A2B".utf8),
                      forType: NSPasteboard.PasteboardType(ProjectTabDrag.type.identifier))
        XCTAssertNil(CanvasDrop.read(board, cardsType: NSPasteboard.PasteboardType("com.stuarthanberg.pm.canvas-nodes")))

        // The control: the same id as plain text is exactly the card this used to make.
        board.clearContents()
        board.setString("0F9C1A2B-3D4E-4F50-8A6B-7C8D9E0F1A2B", forType: .string)
        guard case .text? = CanvasDrop.read(board, cardsType: NSPasteboard.PasteboardType("com.stuarthanberg.pm.canvas-nodes"))
        else { return XCTFail("plain text should still make a text card") }
    }

    // MARK: Reordering

    func testNothingMovesBeforeTheMiddle() {
        let ids = ["canvas", "a", "b", "c"]
        XCTAssertNil(TabReorder.destination(of: "a", over: "b", at: 30, width: 80, in: ids))
        XCTAssertEqual(TabReorder.destination(of: "a", over: "b", at: 50, width: 80, in: ids), 2)
        // Leftwards, the other half.
        XCTAssertNil(TabReorder.destination(of: "c", over: "b", at: 50, width: 80, in: ids))
        XCTAssertEqual(TabReorder.destination(of: "c", over: "b", at: 30, width: 80, in: ids), 2)
        // Over itself is never a move.
        XCTAssertNil(TabReorder.destination(of: "b", over: "b", at: 0, width: 80, in: ids))
    }

    /// **The bounce.** A short chip dragged onto a long one, the pointer held still just past where the
    /// swap puts it: the row has to settle and stay settled.
    func testAShortChipOverALongOneSettles() {
        let widths: [String: CGFloat] = ["canvas": 30, "a": 40, "b": 160, "c": 60]
        for x in stride(from: 70, through: 230, by: 5) {
            let orders = simulate(dragging: "a", pointer: CGFloat(x), widths: widths, rule: .middle)
            XCTAssertEqual(orders.suffix(3).count, 3)
            XCTAssertEqual(Set(orders.suffix(3)).count, 1, "flipping at x=\(x): \(orders.suffix(4))")
        }
    }

    /// The control: the old rule, moving on entering a chip, run over the same row, flips forever at
    /// some pointer position.
    ///
    /// **Only if entry is re-reported for a chip that slides under a still pointer**, which is what the
    /// simulation assumes of SwiftUI's drop tracking and what this bundle cannot watch it do — it can't
    /// drive a real drag. The rule the row uses now doesn't depend on the answer: it is asked on every
    /// update and decides from position alone, so it is stable whether or not entries are re-reported.
    func testTheOldRuleBounces() {
        let widths: [String: CGFloat] = ["canvas": 30, "a": 40, "b": 160, "c": 60]
        let flips = stride(from: 70, through: 230, by: 5).contains { x in
            let orders = simulate(dragging: "a", pointer: CGFloat(x), widths: widths, rule: .enter)
            return Set(orders.suffix(3)).count > 1
        }
        XCTAssertTrue(flips, "the enter rule should reproduce the bounce, or this suite proves nothing")
    }

    private enum Rule { case middle, enter }

    /// The row as `ProjectTabSet.move` keeps it, with the pointer held at `pointer` for a dozen drop
    /// updates. Returns the order after each one.
    private func simulate(dragging: String, pointer: CGFloat, widths: [String: CGFloat],
                          rule: Rule) -> [[String]] {
        var set = ["canvas", "a", "b", "c"]
        var orders: [[String]] = []
        var lastUnder: (id: String, left: CGFloat)?
        for _ in 0..<12 {
            // Which chip the pointer is in, how far into it, and where that chip starts.
            var left: CGFloat = 0
            var under: (id: String, x: CGFloat, left: CGFloat)?
            for id in set {
                let width = widths[id]!
                if pointer >= left, pointer < left + width { under = (id, pointer - left, left) }
                left += width
            }
            if let under {
                let to: Int?
                switch rule {
                case .middle:
                    to = TabReorder.destination(of: dragging, over: under.id, at: under.x,
                                                width: widths[under.id]!, in: set)
                case .enter:
                    // What it used to do: every time the pointer finds itself in a chip — a different
                    // one, or the same one slid to somewhere new under it (see the control's note).
                    let entered = (under.id != lastUnder?.id || under.left != lastUnder?.left)
                        && under.id != dragging
                    to = entered ? set.firstIndex(of: under.id) : nil
                }
                lastUnder = (under.id, under.left)
                if let to, let from = set.firstIndex(of: dragging) {
                    let clamped = min(max(1, to), set.count - 1)
                    if clamped != from { set.insert(set.remove(at: from), at: clamped) }
                }
            }
            orders.append(set)
        }
        return orders
    }

    // MARK: A card that turns up in a workspace

    func testACardTheWorkspaceShowsIsNeverHidden() {
        let layout = CanvasLayout(visible: ["tile"])
        XCTAssertFalse(layout.hides("tile", fading: false, alpha: 1))
        XCTAssertFalse(layout.hides("tile", fading: true, alpha: 0))
        XCTAssertFalse(CanvasLayout.document.hides("anything", fading: false, alpha: 1))
    }

    /// A card the crossing is fading stays drawn until it has faded, so you see it go.
    func testAFadingCardIsHiddenOnlyOnceItHasFaded() {
        let layout = CanvasLayout(visible: ["tile"])
        XCTAssertFalse(layout.hides("other", fading: true, alpha: 0.4))
        XCTAssertTrue(layout.hides("other", fading: true, alpha: 0))
    }

    /// **The stray card.** Made after the workspace opened, so the crossing never faded it and it sits
    /// at full alpha — and is hidden anyway, because the workspace does not show it.
    func testACardMadeAfterTheCrossingIsHidden() {
        let layout = CanvasLayout(visible: ["tile"])
        XCTAssertTrue(layout.hides("stray", fading: false, alpha: 1))
    }

    // MARK: Which cards a crossing fades

    func testGoingIntoAWorkspaceFadesWhatItLeavesOut() {
        XCTAssertEqual(CanvasLayout.fading(from: .document, to: CanvasLayout(visible: ["a"]),
                                           among: ["a", "b", "c"]), ["b", "c"])
    }

    /// On the way out every card is in the layout again, so the ones arriving back are read off the
    /// workspace being left.
    func testComingOutFadesTheSameCardsBackIn() {
        XCTAssertEqual(CanvasLayout.fading(from: CanvasLayout(visible: ["a"]), to: .document,
                                           among: ["a", "b", "c"]), ["b", "c"])
    }

    /// **The invisible tiles.** Putting a maximized tile back, in a workspace holding every card on the
    /// board, is a tiling that shows everything — not a way out. The tiles coming back were marked
    /// fading, drawn at `1 - tiledness` = 0, and stayed that way until a resize.
    func testPuttingBackAMaximizedTileFadesNothingItShows() {
        XCTAssertEqual(CanvasLayout.fading(from: CanvasLayout(visible: ["a"]),
                                           to: CanvasLayout(visible: ["a", "b"]),
                                           among: ["a", "b"]), [])
    }

    /// The same switch between two workspaces, one of which holds the whole board.
    func testSwitchingToAWorkspaceOfTheWholeBoardFadesNothing() {
        XCTAssertEqual(CanvasLayout.fading(from: CanvasLayout(visible: ["b"]),
                                           to: CanvasLayout(visible: ["a", "b", "c"]),
                                           among: ["a", "b", "c"]), [])
    }
}
