import PmLib
import XCTest

/// Which cards a search on the board finds.
///
/// Untested until it moved: it lived on `CanvasBoardView`, and nothing in this bundle can build a
/// board. The case worth having is a web card found by the *name* of its page rather than its
/// address — the half of a card a person remembers, and the half that silently stops working if the
/// title lookup is dropped, since every address-based search still passes.
final class CanvasSearchTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "PMCanvasPageTitles")
        super.tearDown()
    }

    private func node(_ id: String, _ content: CanvasContent) -> CanvasNode {
        CanvasNode(id: id, content: content, frame: CanvasRect(x: 0, y: 0, width: 100, height: 100))
    }

    private let noTitles: (String) -> String? = { _ in nil }

    func testAnEmptyOrBlankQueryFindsNothing() {
        let doc = CanvasDocument(nodes: [node("t", .text("anything"))])
        XCTAssertEqual(CanvasSearch.matches("", in: doc, pageTitle: noTitles), [])
        XCTAssertEqual(CanvasSearch.matches("   ", in: doc, pageTitle: noTitles), [],
                       "a space is not a search for every card with a space in it")
    }

    /// A document card is found by what is written in it, not only by its name.
    @MainActor func testADocumentCardIsFoundByWhatItSays() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let canvas = folder.appendingPathComponent("docs/Board.canvas")
        let file = try CanvasDocCards.write("Vendor call\nAsk about the DPA", in: CanvasDocCards.folder(forCanvasAt: canvas))
        let doc = CanvasDocument(nodes: [node("f", .file(path: file.path, subpath: nil)),
                                         node("l", .file(path: folder.appendingPathComponent("x.png").path, subpath: nil))])
        let resolver = CanvasFileResolver(canvas: canvas)
        XCTAssertEqual(CanvasSearch.matches("dpa", in: doc, pageTitle: noTitles,
                                            fileText: { CanvasSearch.prose(at: $0, resolver: resolver) }), ["f"])
        XCTAssertEqual(CanvasSearch.matches("dpa", in: doc, pageTitle: noTitles), [],
                       "reading files is the board's to ask for")
    }

    func testTextIsMatchedWithoutCaringAboutCase() {
        let doc = CanvasDocument(nodes: [node("t", .text("Quarterly Planning"))])
        XCTAssertEqual(CanvasSearch.matches("planning", in: doc, pageTitle: noTitles), ["t"])
    }

    func testTheQueryIsTrimmed() {
        let doc = CanvasDocument(nodes: [node("t", .text("roadmap"))])
        XCTAssertEqual(CanvasSearch.matches("  roadmap ", in: doc, pageTitle: noTitles), ["t"])
    }

    func testAWebCardIsFoundByItsAddress() {
        let doc = CanvasDocument(nodes: [node("l", .link(url: "https://jira.example.com/browse/PM-4127"))])
        XCTAssertEqual(CanvasSearch.matches("PM-4127", in: doc, pageTitle: noTitles), ["l"])
    }

    /// **The rule worth a test.** Eleven cards reading `jira.example.com/browse/…` are unsearchable by
    /// address; by page name they are not.
    func testAWebCardIsFoundByTheNameOfItsPage() {
        let address = "https://jira.example.com/browse/PM-4127"
        let doc = CanvasDocument(nodes: [node("l", .link(url: address))])
        let titles: (String) -> String? = { $0 == address ? "Billing rollover fails on renewal" : nil }

        XCTAssertEqual(CanvasSearch.matches("billing", in: doc, pageTitle: titles), ["l"],
                       "nothing in the address says billing — only the page's name does")
    }

    func testAFileCardIsFoundByItsPathAndByItsSubpath() {
        let doc = CanvasDocument(nodes: [node("f", .file(path: "Projects/W-1 Flexcompute/Notes.md",
                                                         subpath: "#Decisions"))])
        XCTAssertEqual(CanvasSearch.matches("flexcompute", in: doc, pageTitle: noTitles), ["f"])
        XCTAssertEqual(CanvasSearch.matches("Notes.md", in: doc, pageTitle: noTitles), ["f"])
        XCTAssertEqual(CanvasSearch.matches("decisions", in: doc, pageTitle: noTitles), ["f"])
    }

    func testAFrameIsFoundByItsLabelAndAnUnlabelledOneNeverIs() {
        let doc = CanvasDocument(nodes: [
            node("named", .group(label: "Research", background: nil, backgroundStyle: nil)),
            node("bare", .group(label: nil, background: nil, backgroundStyle: nil)),
        ])
        XCTAssertEqual(CanvasSearch.matches("research", in: doc, pageTitle: noTitles), ["named"])
        XCTAssertEqual(CanvasSearch.matches("e", in: doc, pageTitle: noTitles), ["named"])
    }

    /// File order, not a relevance score — `findNext` steps through these, and a stable order is what
    /// makes "next" mean the same thing twice.
    func testMatchesComeBackInTheOrderTheCardsSitInTheFile() {
        let doc = CanvasDocument(nodes: [node("z", .text("plan B")),
                                         node("a", .text("unrelated")),
                                         node("m", .text("the plan"))])
        XCTAssertEqual(CanvasSearch.matches("plan", in: doc, pageTitle: noTitles), ["z", "m"])
    }

    /// The board passes no title lookup, so this checks the default really is the app's remembered
    /// titles — a default of `{ _ in nil }` would pass every test above.
    func testTheDefaultLookupIsTheRememberedPageTitles() {
        let address = "https://wiki.example.com/q3"
        CanvasPageTitles.remember("Q3 Planning", for: address)
        let doc = CanvasDocument(nodes: [node("l", .link(url: address))])

        XCTAssertEqual(CanvasSearch.matches("planning", in: doc), ["l"])
    }
}
