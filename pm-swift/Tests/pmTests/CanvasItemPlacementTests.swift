import XCTest
@testable import PmLib

/// Where a card goes when nobody said where (docs/items.md D6).
///
/// The failures worth guarding are the ones that damage an arrangement somebody made: landing a new
/// card on top of an old one, moving cards that were already placed, or growing a frame over its
/// neighbours. None of those are visible from the list that caused them.
final class CanvasItemPlacementTests: XCTestCase {

    private func card(_ id: String, _ x: Double, _ y: Double, _ w: Double = 400, _ h: Double = 400) -> CanvasNode {
        CanvasNode(id: id, content: .text(id), frame: CanvasRect(x: x, y: y, width: w, height: h))
    }

    private func frame(_ id: String, _ label: String?, _ x: Double, _ y: Double,
                       _ w: Double, _ h: Double) -> CanvasNode {
        CanvasNode(id: id, content: .group(label: label, background: nil, backgroundStyle: nil),
                   frame: CanvasRect(x: x, y: y, width: w, height: h))
    }

    // MARK: The Inbox

    func testTheFirstItemWithNoFrameMakesTheInbox() {
        var document = CanvasDocument(nodes: [card("a", 0, 0)])
        let node = CanvasItemPlacement.add(.text("New"), to: &document)
        let inbox = document.nodes.first { $0.isGroup }
        XCTAssertEqual(inbox.map(canvasFrameLabel), "Inbox")
        XCTAssertNotNil(inbox)
        XCTAssertTrue(inbox!.frame.contains(x: node.frame.midX, y: node.frame.midY),
                      "the card it was made for is inside it")
    }

    func testTheInboxIsMadeOnceAndReusedAfterwards() {
        var document = CanvasDocument()
        CanvasItemPlacement.add(.text("one"), to: &document)
        CanvasItemPlacement.add(.text("two"), to: &document)
        CanvasItemPlacement.add(.text("three"), to: &document)
        XCTAssertEqual(document.nodes.filter(\.isGroup).count, 1)
        XCTAssertEqual(document.nodes.filter { !$0.isGroup }.count, 3)
    }

    /// The whole point of a frame rather than a pile: three added items are three cells, in the order
    /// they were typed.
    func testItemsFillTheGridLeftToRightAndThenDown() {
        var document = CanvasDocument()
        let one = CanvasItemPlacement.add(.text("one"), to: &document)
        let two = CanvasItemPlacement.add(.text("two"), to: &document)
        let three = CanvasItemPlacement.add(.text("three"), to: &document)
        let four = CanvasItemPlacement.add(.text("four"), to: &document)
        XCTAssertEqual(one.frame.minY, two.frame.minY, "the first three are one row")
        XCTAssertEqual(two.frame.minY, three.frame.minY)
        XCTAssertLessThan(one.frame.minX, two.frame.minX)
        XCTAssertLessThan(two.frame.minX, three.frame.minX)
        XCTAssertEqual(four.frame.minX, one.frame.minX, "the fourth starts the next row")
        XCTAssertGreaterThan(four.frame.minY, one.frame.minY)
        XCTAssertFalse(one.frame.intersects(two.frame))
    }

    /// A new frame goes below what is already there, never over it.
    func testANewInboxClearsEverythingAlreadyOnTheBoard() {
        var document = CanvasDocument(nodes: [card("a", 0, 0), card("b", 600, 200)])
        CanvasItemPlacement.add(.text("new"), to: &document)
        let inbox = document.nodes.first { $0.isGroup }!
        for existing in [document.node(id: "a")!, document.node(id: "b")!] {
            XCTAssertFalse(inbox.frame.intersects(existing.frame), "the Inbox covers nothing")
        }
    }

    // MARK: Which frame is the Inbox

    private func role(_ node: CanvasNode?) -> String? {
        node?.extra[CanvasItemPlacement.roleKey]?.stringValue
    }

    func testTheInboxIsMarkedWhenItIsMade() {
        var document = CanvasDocument()
        CanvasItemPlacement.add(.text("new"), to: &document)
        XCTAssertEqual(role(document.nodes.first { $0.isGroup }), "inbox")
    }

    /// A frame somebody drew and called Inbox is the Inbox. Adopting it — rather than making a second
    /// frame with the same name — is the whole reason the mark is written on the way past.
    func testAFrameSomebodyCalledInboxIsAdoptedAndMarked() {
        var document = CanvasDocument(nodes: [frame("f", "inbox", 0, 0, 1400, 600)])
        let node = CanvasItemPlacement.add(.text("new"), to: &document)
        XCTAssertEqual(document.nodes.filter(\.isGroup).count, 1, "no second Inbox")
        XCTAssertTrue(document.node(id: "f")!.frame.contains(x: node.frame.midX, y: node.frame.midY))
        XCTAssertEqual(role(document.node(id: "f")), "inbox")
    }

    /// The point of an id: the frame you have been filling stays the frame you fill, under any name.
    func testARenamedInboxIsStillTheInbox() {
        var document = CanvasDocument()
        CanvasItemPlacement.add(.text("one"), to: &document)
        let inbox = document.nodes.first { $0.isGroup }!.id
        let index = document.nodes.firstIndex { $0.id == inbox }!
        document.nodes[index].content = .group(label: "Reading", background: nil, backgroundStyle: nil)

        let node = CanvasItemPlacement.add(.text("two"), to: &document)
        XCTAssertEqual(document.nodes.filter(\.isGroup).count, 1, "no Inbox was made alongside it")
        XCTAssertTrue(document.node(id: inbox)!.frame.contains(x: node.frame.midX, y: node.frame.midY))
    }

    /// And the other half of that: a board with both answers uses the marked one, which is what stops
    /// a frame called Inbox that PM never chose from quietly taking over.
    func testTheMarkedFrameWinsOverAFrameMerelyCalledInbox() {
        var marked = frame("m", "Reading", 0, 0, 1400, 600)
        marked.extra[CanvasItemPlacement.roleKey] = .string(CanvasItemPlacement.inboxRole)
        var document = CanvasDocument(nodes: [marked, frame("theirs", "Inbox", 0, 2000, 1400, 600)])
        let node = CanvasItemPlacement.add(.text("new"), to: &document)
        XCTAssertTrue(document.node(id: "m")!.frame.contains(x: node.frame.midX, y: node.frame.midY))
        XCTAssertNil(role(document.node(id: "theirs")), "somebody else's frame is left alone")
    }

    /// The mark is an unknown key to every other program, and unknown keys are kept verbatim — so the
    /// Inbox is still the Inbox after a board has been round-tripped through the file.
    func testTheMarkSurvivesTheFile() throws {
        var document = CanvasDocument()
        CanvasItemPlacement.add(.text("new"), to: &document)
        let reread = try CanvasDocument.parse(Data(document.serialized().utf8))
        XCTAssertEqual(CanvasItemPlacement.inbox(of: reread)?.id, document.nodes.first { $0.isGroup }?.id)
        XCTAssertEqual(role(CanvasItemPlacement.inbox(of: reread)), "inbox")
    }

    /// Only the Inbox is marked: `--frame Reading` makes an ordinary frame, found by its label.
    func testAFrameMadeByLabelCarriesNoRole() {
        var document = CanvasDocument()
        let id = CanvasItemPlacement.frame(labelled: "Reading", in: &document)
        XCTAssertNil(role(document.node(id: id)))
        XCTAssertEqual(CanvasItemPlacement.frame(labelled: "reading", in: &document), id,
                       "and is found again whatever case you type")
    }

    // MARK: Moving what is already there

    func testAMovedCardJoinsTheFrameItWasDroppedOn() {
        var document = CanvasDocument(nodes: [card("a", 0, 0), frame("f", "Reference", 2000, 0, 900, 600)])
        XCTAssertEqual(CanvasItemPlacement.move(["a"], to: "f", in: &document), ["a"])
        let moved = document.node(id: "a")!.frame
        XCTAssertTrue(document.node(id: "f")!.frame.contains(x: moved.midX, y: moved.midY))
        XCTAssertEqual(document.nodes.count, 2, "moved, not copied")
    }

    /// Dropping a card on the section it is already in is a no-op, not a shuffle to the end: the list
    /// is sorted, so there is no place in it that moving the card would have taken it to.
    func testACardAlreadyInTheFrameIsLeftAlone() {
        var document = CanvasDocument(nodes: [frame("f", "Reference", 0, 0, 900, 600), card("a", 20, 40)])
        let before = document.node(id: "a")!.frame
        XCTAssertEqual(CanvasItemPlacement.move(["a"], to: "f", in: &document), [])
        XCTAssertEqual(document.node(id: "a")!.frame, before)
    }

    func testSeveralMovedCardsTakeSuccessiveSlotsAndDoNotOverlap() {
        var document = CanvasDocument(nodes: [card("a", 0, 0), card("b", 500, 0), card("c", 1000, 0),
                                              frame("f", "Reference", 0, 2000, 1400, 600)])
        XCTAssertEqual(CanvasItemPlacement.move(["a", "b", "c"], to: "f", in: &document), ["a", "b", "c"])
        let rects = ["a", "b", "c"].map { document.node(id: $0)!.frame }
        for (one, two) in zip(rects, rects.dropFirst()) { XCTAssertFalse(one.intersects(two)) }
        for rect in rects {
            XCTAssertTrue(document.node(id: "f")!.frame.contains(x: rect.midX, y: rect.midY))
        }
    }

    /// A drop that names no frame means the Inbox, exactly as an add that names none does — the list's
    /// loose section has an add row with the same rule behind it.
    func testAMoveWithNoFrameGoesToTheInbox() {
        var document = CanvasDocument(nodes: [card("a", 0, 0)])
        CanvasItemPlacement.move(["a"], in: &document)
        let inbox = document.nodes.first { $0.isGroup }!
        XCTAssertEqual(canvasFrameLabel(inbox), "Inbox")
        let moved = document.node(id: "a")!.frame
        XCTAssertTrue(inbox.frame.contains(x: moved.midX, y: moved.midY))
    }

    /// The frame grows for what it is given, and nothing else on the board is touched.
    func testTheDestinationGrowsAndTheRestOfTheBoardStaysPut() {
        var document = CanvasDocument(nodes: [card("a", 0, 0), card("bystander", 600, 0),
                                              frame("f", "Reference", 0, 2000, 900, 100)])
        CanvasItemPlacement.move(["a"], to: "f", in: &document)
        XCTAssertGreaterThan(document.node(id: "f")!.frame.height, 100)
        XCTAssertEqual(document.node(id: "bystander")!.frame, card("bystander", 600, 0).frame)
    }

    /// Ids that name nothing, or name a frame, move nothing — and a move of nothing does not conjure
    /// an Inbox to move it into.
    func testMovingNothingMakesNothing() {
        var document = CanvasDocument(nodes: [frame("f", "Reference", 0, 0, 900, 600)])
        XCTAssertEqual(CanvasItemPlacement.move(["gone", "f"], in: &document), [])
        XCTAssertEqual(document.nodes.count, 1)
    }

    // MARK: A named frame

    func testAnItemAddedUnderAFrameJoinsThatFrame() {
        var document = CanvasDocument(nodes: [frame("f", "Reference", 0, 0, 1000, 600)])
        let node = CanvasItemPlacement.add(.link(url: "https://example.com"), to: &document, frame: "f")
        XCTAssertTrue(document.node(id: "f")!.frame.contains(x: node.frame.midX, y: node.frame.midY))
        XCTAssertEqual(document.nodes.filter(\.isGroup).count, 1, "no Inbox was made")
    }

    func testTheFrameGrowsToHoldWhatWasAddedAndNeverShrinks() {
        var document = CanvasDocument(nodes: [frame("f", "Reference", 0, 0, 1000, 200)])
        let node = CanvasItemPlacement.add(.text("new"), to: &document, frame: "f")
        let grown = document.node(id: "f")!.frame
        XCTAssertGreaterThanOrEqual(grown.maxY, node.frame.maxY)
        XCTAssertGreaterThan(grown.height, 200)

        let tall = CanvasDocument(nodes: [frame("f", "Reference", 0, 0, 1000, 4000)])
        var second = tall
        CanvasItemPlacement.add(.text("new"), to: &second, frame: "f")
        XCTAssertEqual(second.node(id: "f")!.frame.height, 4000, "a roomy frame is left alone")
    }

    /// A stale id from a list that hasn't reloaded must not lose the card.
    func testAFrameThatHasGoneFallsBackToTheInbox() {
        var document = CanvasDocument(nodes: [card("a", 0, 0)])
        let node = CanvasItemPlacement.add(.text("new"), to: &document, frame: "vanished")
        let inbox = document.nodes.first { $0.isGroup }!
        XCTAssertEqual(canvasFrameLabel(inbox), "Inbox")
        XCTAssertTrue(inbox.frame.contains(x: node.frame.midX, y: node.frame.midY))
    }

    /// Adding must never move what is already placed — the arrangement is the thing being protected.
    func testNothingAlreadyOnTheBoardMoves() {
        var document = CanvasDocument(nodes: [card("a", 0, 0), frame("f", "Reference", 800, 0, 900, 600),
                                              card("b", 850, 60)])
        let before = document.nodes.filter { $0.id != "f" }.map(\.frame)
        CanvasItemPlacement.add(.text("new"), to: &document, frame: "f")
        let after = document.nodes.filter { $0.id == "a" || $0.id == "b" }.map(\.frame)
        XCTAssertEqual(Array(before.prefix(2)), after)
    }

    /// The new card takes the slot after the ones already in the frame, rather than the first free one.
    func testASlotIsCountedFromWhatTheFrameHoldsNotSearchedFor() {
        var document = CanvasDocument(nodes: [frame("f", "Reference", 0, 0, 2000, 600),
                                              card("held", 20, 40)])
        let node = CanvasItemPlacement.add(.text("new"), to: &document, frame: "f")
        XCTAssertFalse(node.frame.intersects(document.node(id: "held")!.frame))
    }
}
