import XCTest
import PmLib
@testable import PMViewTests

/// What Add Card from Canvas offers a tiled view, in what order, and under what names.
///
/// The parts worth pinning are the ones a menu would get quietly wrong: offering a card that is already
/// up or a frame that can't be a tile, losing where the cards sit on the board, and naming a card by
/// something other than what the board calls it.
@MainActor
final class CanvasExistingCardsTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "PMCanvasPageTitles")
        super.tearDown()
    }

    private func text(_ id: String, _ body: String, _ x: Double, _ y: Double) -> CanvasNode {
        CanvasNode(id: id, content: .text(body), frame: CanvasRect(x: x, y: y, width: 200, height: 150))
    }

    private func frame(_ id: String, _ label: String?,
                       _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CanvasNode {
        CanvasNode(id: id, content: .group(label: label, background: nil, backgroundStyle: nil),
                   frame: CanvasRect(x: x, y: y, width: w, height: h))
    }

    private func node(_ content: CanvasContent) -> CanvasNode {
        CanvasNode(id: "n", content: content, frame: CanvasRect(x: 0, y: 0, width: 200, height: 150))
    }

    // MARK: What is offered

    func testOffersOnlyTheCardsThatAreNotShowingAndNeverAFrame() {
        let document = CanvasDocument(nodes: [
            text("a", "A", 0, 0),
            text("b", "B", 300, 0),
            frame("f", "Empty Frame", 2000, 2000, 600, 400),
        ])
        let offered = CanvasExistingCards.sections(of: document, showing: ["a"]).flatMap(\.cards).map(\.id)
        XCTAssertEqual(offered, ["b"])
    }

    /// Nothing at all, not an empty section — the menus leave the item out when this is empty.
    func testNothingWhenEveryCardIsShowing() {
        let document = CanvasDocument(nodes: [
            text("a", "A", 0, 0),
            text("b", "B", 300, 0),
            frame("f", "Frame", 0, 0, 600, 400),
        ])
        XCTAssertEqual(CanvasExistingCards.sections(of: document, showing: ["a", "b"]), [])
    }

    // MARK: Where they sit

    /// Loose cards first under no header, then a section per frame in the order the frames sit on the
    /// board — not the order they happen to be in the file — and reading order inside each.
    func testLooseCardsFirstThenEachFrameInReadingOrder() {
        let document = CanvasDocument(nodes: [
            frame("right", "Right", 800, 500, 600, 400),
            frame("left", "Left", 0, 500, 600, 400),
            text("q", "Q", 1100, 550),
            text("r", "R", 850, 550),
            text("p", "P", 50, 550),
            text("loose", "Loose", 0, 0),
        ])
        let sections = CanvasExistingCards.sections(of: document, showing: [])
        XCTAssertEqual(sections.map(\.frame), [nil, "Left", "Right"])
        XCTAssertEqual(sections.map { $0.cards.map(\.id) }, [["loose"], ["p"], ["r", "q"]])
    }

    func testACardInANestedFrameIsListedUnderTheInnerOne() {
        let document = CanvasDocument(nodes: [
            frame("outer", "Outer", 0, 0, 1000, 1000),
            frame("inner", "Inner", 100, 100, 400, 400),
            text("a", "A", 150, 150),
            text("b", "B", 700, 700),
        ])
        // Which frame each card is under, not the order of the frames: two nested frames are one row of
        // the board, and which comes first is `CanvasTiling.order`'s call about their centres.
        let sections = CanvasExistingCards.sections(of: document, showing: [])
        let under = Dictionary(uniqueKeysWithValues: sections.map { ($0.frame, $0.cards.map(\.id)) })
        XCTAssertEqual(under, ["Inner": ["a"], "Outer": ["b"]])
    }

    func testAFrameWithNoNameIsCalledFrame() {
        let document = CanvasDocument(nodes: [
            frame("f", "   ", 0, 0, 600, 400),
            text("a", "A", 50, 50),
        ])
        XCTAssertEqual(CanvasExistingCards.sections(of: document, showing: []).map(\.frame), ["Frame"])
    }

    // MARK: What they are called

    func testATextCardIsNamedByItsFirstLineWithoutMarkdown() {
        XCTAssertEqual(CanvasExistingCards.card(node(.text("# Launch plan\nThe rest")))?.name, "Launch plan")
        XCTAssertEqual(CanvasExistingCards.card(node(.text("")))?.name, "Empty Card")
        XCTAssertEqual(CanvasExistingCards.card(node(.text("x")))?.kind, .text)
    }

    func testALongFirstLineIsCut() {
        let name = CanvasExistingCards.card(node(.text(String(repeating: "word ", count: 40))))?.name ?? ""
        XCTAssertLessThanOrEqual(name.count, CanvasExistingCards.longestName)
        XCTAssertTrue(name.hasSuffix("\u{2026}"))
    }

    /// Named the way the board names the card zoomed out: for the project, without `Notes - `.
    func testAProjectsNotesAreNamedForTheProject() {
        let path = "01 Projects/Acme/docs/Notes - Acme Launch.md"
        let card = CanvasExistingCards.card(node(.file(path: path, subpath: nil)))
        XCTAssertEqual(card?.name, "Acme Launch")
        XCTAssertEqual(card?.kind, .file(symbol: "doc.text"))
        XCTAssertEqual(CanvasExistingCards.card(node(.file(path: path, subpath: "#Tasks")))?.name,
                       "Acme Launch \u{00B7} Tasks")
    }

    /// Only a project's notes lose the prefix — any other file keeps the name it has.
    func testAnyOtherFileKeepsItsName() {
        let card = CanvasExistingCards.card(node(.file(path: "Reference/Notes - Misc.pdf", subpath: nil)))
        XCTAssertEqual(card?.name, "Notes - Misc")
        XCTAssertEqual(card?.kind, .file(symbol: "doc.richtext"))
    }

    func testAPageIsNamedByItsRememberedTitleElseItsHost() {
        let address = "https://tracker.example.com/browse/PM-1"
        let before = CanvasExistingCards.card(node(.link(url: address)))
        XCTAssertEqual(before?.name, "tracker.example.com")
        XCTAssertEqual(before?.kind, .page(host: "tracker.example.com"))

        CanvasPageTitles.remember("Billing rollover fails on renewal", for: address)
        XCTAssertEqual(CanvasExistingCards.card(node(.link(url: address)))?.name,
                       "Billing rollover fails on renewal")
    }

    /// A folder is stored as a file card, so only the disk can say it is one — and when it is, it is
    /// named whole (a dot is not an extension) and drawn with a folder, in a menu, a tab and a proxy.
    func testAFolderIsNamedWholeAndDrawnAsAFolder() {
        let path = "Reference/Q3.drafts"
        let card = CanvasExistingCards.card(node(.file(path: path, subpath: nil)), isFolder: { $0 == path })
        XCTAssertEqual(card?.name, "Q3.drafts")
        XCTAssertEqual(card?.kind, .file(symbol: "folder"))
        XCTAssertEqual(CanvasExistingCards.card(node(.file(path: path, subpath: nil)))?.kind, .file(symbol: "doc"))
    }

    // MARK: What can be added

    /// Every surface builds its add items from `CanvasAddCommand.offered`, so this is what each offers.
    func testEveryKindOfCardIsOfferedAndTheProjectNoteOnlyWhenMissing() {
        XCTAssertEqual(CanvasAddCommand.offered(projectNote: false), [.card, .frame, .link, .file, .folder, .dayView, .waitingView, .searchView])
        XCTAssertEqual(CanvasAddCommand.offered(projectNote: true).last, .projectNote)
        XCTAssertEqual(CanvasAddCommand.folder.title, "New Folder\u{2026}")
        XCTAssertEqual(CanvasAddCommand.dayView.title, "New Day View")
    }

    /// A tile's strip offers what can be a tab: everything but a frame.
    func testATabCanBeAnythingButAFrame() {
        XCTAssertEqual(CanvasAddCommand.offered(projectNote: true).filter(\.makesTile),
                       [.card, .link, .file, .folder, .dayView, .waitingView, .searchView, .projectNote])
    }
}
