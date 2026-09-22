import XCTest
@testable import PmLib

/// A board read as items: what each card is called, which frame it is under, and what orders them
/// (docs/items.md D2–D4).
///
/// The risks these carry are the ones a list gets quietly wrong. Naming a card by something other than
/// what the board calls it — a Day card by the line stored in its node — puts two names on one thing.
/// Losing where a card sits throws away the only arrangement anybody made. And a sort that isn't total
/// reshuffles a list between two reads of an unchanged file, which is the fastest way to make a list
/// untrustworthy.
final class CanvasItemTests: XCTestCase {

    private func text(_ id: String, _ body: String, _ x: Double = 0, _ y: Double = 0) -> CanvasNode {
        CanvasNode(id: id, content: .text(body), frame: CanvasRect(x: x, y: y, width: 200, height: 150))
    }

    private func frame(_ id: String, _ label: String?,
                       _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CanvasNode {
        CanvasNode(id: id, content: .group(label: label, background: nil, backgroundStyle: nil),
                   frame: CanvasRect(x: x, y: y, width: w, height: h))
    }

    // MARK: What one card is

    func testACardIsNamedByTheLineThatStandsForIt() {
        let item = CanvasItem.of(text("a", "# Launch plan\nthe rest"))
        XCTAssertEqual(item?.title, "Launch plan")
        XCTAssertEqual(item?.kind, .text)
    }

    func testAnEmptyCardStillHasAName() {
        XCTAssertEqual(CanvasItem.of(text("a", ""))?.title, "Empty Card")
    }

    func testAFileCardCarriesItsFolderAsItsSecondLine() {
        let node = CanvasNode(id: "f", content: .file(path: "Reference/specs/api.md", subpath: nil),
                              frame: CanvasRect(x: 0, y: 0, width: 200, height: 150))
        let item = CanvasItem.of(node)
        XCTAssertEqual(item?.title, "api")
        XCTAssertEqual(item?.detail, "Reference/specs")
        XCTAssertEqual(item?.kind, .file(symbol: "doc.text"))
    }

    /// The host is the title when nothing better has been seen, and then saying it twice is noise.
    func testAPageSaysItsHostOnlyWhenTheTitleIsNotAlreadyTheHost() {
        let url = "https://tracker.example.com/browse/PM-1"
        let node = CanvasNode(id: "p", content: .link(url: url),
                              frame: CanvasRect(x: 0, y: 0, width: 200, height: 150))
        XCTAssertNil(CanvasItem.of(node)?.detail)
        XCTAssertEqual(CanvasItem.of(node)?.title, "tracker.example.com")

        let named = CanvasItemLookups(pageTitle: { _ in "Billing rollover fails" })
        XCTAssertEqual(CanvasItem.of(node, lookups: named)?.title, "Billing rollover fails")
        XCTAssertEqual(CanvasItem.of(node, lookups: named)?.detail, "tracker.example.com")
    }

    /// A view is a text node carrying `pmView`, and without asking it every lens would call a Today
    /// card by its stored line. With no app to ask, the kind's own name is the answer.
    func testAViewIsItsKindRatherThanItsStoredText() {
        var node = text("v", "Today, across projects: a Folio view.")
        node.extra[CanvasViewKind.nodeKey] = .string("day")
        XCTAssertEqual(CanvasItem.of(node)?.title, "Day")
        XCTAssertEqual(CanvasItem.of(node)?.kind, .view(symbol: "calendar"))

        let app = CanvasItemLookups(viewTitle: { _ in "Yesterday" })
        XCTAssertEqual(CanvasItem.of(node, lookups: app)?.title, "Yesterday")
    }

    /// Forgiving, the way views.md D3 asks: a view this build hasn't got is the text card it also is.
    func testAnUnknownViewIsAnOrdinaryTextCard() {
        var node = text("v", "Some newer view")
        node.extra[CanvasViewKind.nodeKey] = .string("burndown")
        XCTAssertEqual(CanvasItem.of(node)?.kind, .text)
        XCTAssertEqual(CanvasItem.of(node)?.title, "Some newer view")
    }

    func testAFrameIsNotAnItem() {
        XCTAssertNil(CanvasItem.of(frame("f", "Reference", 0, 0, 600, 400)))
    }

    // MARK: Where it sits

    func testLooseItemsFirstThenEachFrameInReadingOrder() {
        let document = CanvasDocument(nodes: [
            frame("right", "Right", 800, 500, 600, 400),
            frame("left", "Left", 0, 500, 600, 400),
            text("q", "Q", 1100, 550),
            text("r", "R", 850, 550),
            text("p", "P", 50, 550),
            text("loose", "Loose", 0, 0),
        ])
        let sections = CanvasItems.sections(of: document)
        XCTAssertEqual(sections.map(\.label), [nil, "Left", "Right"])
        XCTAssertEqual(sections.map(\.frame), [nil, "left", "right"])
        XCTAssertEqual(sections.map { $0.items.map(\.id) }, [["loose"], ["p"], ["r", "q"]])
    }

    /// The section knows the frame's id as well as its label, because the lenses that act — adding into
    /// a frame, dragging a row between two of them — point at the frame rather than at what it is called.
    func testAnItemCarriesTheFrameItIsUnder() {
        let document = CanvasDocument(nodes: [
            frame("f", "Reference", 0, 0, 600, 400),
            text("a", "A", 50, 50),
            text("b", "B", 2000, 2000),
        ])
        let items = CanvasItems.all(of: document)
        XCTAssertEqual(items.first { $0.id == "a" }?.frame, "f")
        XCTAssertNil(items.first { $0.id == "b" }?.frame)
    }

    // MARK: What orders them

    private var mixed: CanvasDocument {
        // Written in one order, sitting on the board in another: b is above a, and c is to a's right.
        var page = CanvasNode(id: "c", content: .link(url: "https://zebra.example.com/"),
                              frame: CanvasRect(x: 300, y: 400, width: 200, height: 150))
        page.color = nil
        return CanvasDocument(nodes: [
            text("a", "Middle", 0, 400),
            page,
            text("b", "Apples", 0, 0),
        ])
    }

    func testReadingOrderIsDownAndAcrossTheBoard() {
        XCTAssertEqual(CanvasItems.all(of: mixed, sort: .reading).map(\.id), ["b", "a", "c"])
    }

    func testFileOrderIsTheOrderTheNodesSitInTheFile() {
        XCTAssertEqual(CanvasItems.all(of: mixed, sort: .file).map(\.id), ["a", "c", "b"])
    }

    func testNameSortsByWhatTheCardIsCalledNotByWhatItIs() {
        XCTAssertEqual(CanvasItems.all(of: mixed, sort: .name).map(\.title),
                       ["Apples", "Middle", "zebra.example.com"])
    }

    func testKindPutsThePagesTogether() {
        XCTAssertEqual(CanvasItems.all(of: mixed, sort: .kind).map(\.id), ["b", "a", "c"])
    }

    /// Two cards called the same thing must not swap places between two reads of an unchanged file.
    func testTitleTiesAreBrokenSoTheOrderIsStable() {
        let document = CanvasDocument(nodes: [
            text("z", "Notes", 0, 0),
            text("a", "Notes", 300, 0),
        ])
        let once = CanvasItems.all(of: document, sort: .name).map(\.id)
        XCTAssertEqual(once, ["a", "z"])
        XCTAssertEqual(CanvasItems.all(of: document, sort: .name).map(\.id), once)
    }

    /// The sort is inside a section: a frame's items are ordered among themselves, and the frames stay
    /// where they sit on the board however the items within them are being read.
    func testSortingHappensWithinASectionRatherThanAcrossTheBoard() {
        let document = CanvasDocument(nodes: [
            frame("f", "Reference", 0, 500, 600, 400),
            text("late", "Zulu", 50, 550),
            text("early", "Alpha", 300, 550),
            text("loose", "Mike", 0, 0),
        ])
        let sections = CanvasItems.sections(of: document, sort: .name)
        XCTAssertEqual(sections.map(\.label), [nil, "Reference"])
        XCTAssertEqual(sections.last?.items.map(\.title), ["Alpha", "Zulu"])
    }

    // MARK: What a picker asks of it

    func testShowingLeavesCardsOutAndFirstLeadsTheList() {
        let document = CanvasDocument(nodes: [
            frame("f", "Reference", 0, 500, 600, 400),
            text("note", "The project", 50, 550),
            text("a", "A", 0, 0),
            text("b", "B", 300, 0),
        ])
        let sections = CanvasItems.sections(of: document, showing: ["a"], first: "note")
        XCTAssertEqual(sections.map { $0.items.map(\.id) }, [["note", "b"]],
                       "the lead card comes first and leaves its frame, which then has nothing left")
    }

    func testNothingAtAllWhenEveryCardIsShowing() {
        let document = CanvasDocument(nodes: [text("a", "A"), frame("f", "Reference", 0, 0, 600, 400)])
        XCTAssertEqual(CanvasItems.sections(of: document, showing: ["a"]).count, 0)
    }
}
