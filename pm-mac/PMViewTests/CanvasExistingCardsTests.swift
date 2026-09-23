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
        let offered = CanvasExistingCards.sections(of: document, showing: ["a"]).flatMap(\.items).map(\.id)
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
        XCTAssertEqual(sections.map(\.label), [nil, "Left", "Right"])
        XCTAssertEqual(sections.map { $0.items.map(\.id) }, [["loose"], ["p"], ["r", "q"]])
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
        let under = Dictionary(uniqueKeysWithValues: sections.map { ($0.label, $0.items.map(\.id)) })
        XCTAssertEqual(under, ["Inner": ["a"], "Outer": ["b"]])
    }

    func testAFrameWithNoNameIsCalledFrame() {
        let document = CanvasDocument(nodes: [
            frame("f", "   ", 0, 0, 600, 400),
            text("a", "A", 50, 50),
        ])
        XCTAssertEqual(CanvasExistingCards.sections(of: document, showing: []).map(\.label), ["Frame"])
    }

    // MARK: What they are called

    func testATextCardIsNamedByItsFirstLineWithoutMarkdown() {
        XCTAssertEqual(CanvasExistingCards.card(node(.text("# Launch plan\nThe rest")))?.title, "Launch plan")
        XCTAssertEqual(CanvasExistingCards.card(node(.text("")))?.title, "Empty Card")
        XCTAssertEqual(CanvasExistingCards.card(node(.text("x")))?.kind, .text)
    }

    func testALongFirstLineIsCut() {
        let name = CanvasExistingCards.card(node(.text(String(repeating: "word ", count: 40))))?.title ?? ""
        XCTAssertLessThanOrEqual(name.count, CanvasItem.longestTitle)
        XCTAssertTrue(name.hasSuffix("\u{2026}"))
    }

    /// Named the way the board names the card zoomed out: for the project, without `Notes - `.
    func testAProjectsNotesAreNamedForTheProject() {
        let path = "01 Projects/Acme/docs/Notes - Acme Launch.md"
        let card = CanvasExistingCards.card(node(.file(path: path, subpath: nil)))
        XCTAssertEqual(card?.title, "Acme Launch")
        XCTAssertEqual(card?.kind, .file(symbol: "doc.text"))
        XCTAssertEqual(CanvasExistingCards.card(node(.file(path: path, subpath: "#Tasks")))?.title,
                       "Acme Launch \u{00B7} Tasks")
    }

    /// Only a project's notes lose the prefix — any other file keeps the name it has.
    func testAnyOtherFileKeepsItsName() {
        let card = CanvasExistingCards.card(node(.file(path: "Reference/Notes - Misc.pdf", subpath: nil)))
        XCTAssertEqual(card?.title, "Notes - Misc")
        XCTAssertEqual(card?.kind, .file(symbol: "doc.richtext"))
    }

    func testAPageIsNamedByItsRememberedTitleElseItsHost() {
        let address = "https://tracker.example.com/browse/PM-1"
        let before = CanvasExistingCards.card(node(.link(url: address)))
        XCTAssertEqual(before?.title, "tracker.example.com")
        XCTAssertEqual(before?.kind, .page(host: "tracker.example.com"))

        CanvasPageTitles.remember("Billing rollover fails on renewal", for: address)
        XCTAssertEqual(CanvasExistingCards.card(node(.link(url: address)))?.title,
                       "Billing rollover fails on renewal")
    }

    /// A tab names the page that is running, not the name remembered when the card last loaded it.
    func testARunningPagesOwnTitleBeatsTheRememberedOne() {
        let address = "https://app.slack.com/client/T1/D1"
        CanvasPageTitles.remember("* Sam (DM) - Acme - Slack", for: address)
        let card = CanvasExistingCards.card(node(.link(url: address)), liveTitle: "Sam (DM) - Acme - Slack")
        XCTAssertEqual(card?.title, "Sam (DM) - Acme - Slack")
    }

    /// A folder is stored as a file card, so only the disk can say it is one — and when it is, it is
    /// named whole (a dot is not an extension) and drawn with a folder, in a menu, a tab and a proxy.
    func testAFolderIsNamedWholeAndDrawnAsAFolder() {
        let path = "Reference/Q3.drafts"
        let card = CanvasExistingCards.card(node(.file(path: path, subpath: nil)), isFolder: { $0 == path })
        XCTAssertEqual(card?.title, "Q3.drafts")
        XCTAssertEqual(card?.kind, .file(symbol: "folder"))
        XCTAssertEqual(CanvasExistingCards.card(node(.file(path: path, subpath: nil)))?.kind, .file(symbol: "doc"))
    }

    /// A view is stored as a text node, so without asking it the tab, the menu and the proxy all called
    /// a Today card by its stored line and drew the text-card icon. Every kind names itself once, on its
    /// spec, and every surface reads that.
    func testAViewIsNamedAndDrawnAsItselfNotAsItsStoredText() {
        for kind in CanvasViewSpec.Kind.allCases {
            var view = node(.text("stored line"))
            CanvasViewSpec.set(CanvasViewSpec(kind: kind), on: &view)
            let spec = CanvasViewSpec.of(view)!
            let card = CanvasExistingCards.card(view)
            XCTAssertEqual(card?.kind, .view(symbol: spec.symbol), "\(kind)")
            XCTAssertEqual(card?.title, spec.cardName, "\(kind)")
            XCTAssertNotEqual(card?.title, "stored line", "\(kind)")
        }
        var today = node(.text("Today"))
        CanvasViewSpec.set(CanvasViewSpec(kind: .day), on: &today)
        XCTAssertEqual(CanvasExistingCards.card(today)?.kind, .view(symbol: "calendar"))
    }

    // MARK: What can be added

    /// Every surface builds its add items from `CanvasAddCommand.offered`, so this is what each offers —
    /// in the order it offers them, which is the order the headings group them in.
    func testEveryKindOfCardIsOfferedAndTheProjectNoteOnlyWhenMissing() {
        XCTAssertEqual(CanvasAddCommand.offered(projectNote: false), [.card, .web, .privateWeb, .file, .folder, .dayView, .leftoversView, .comingUpView, .projectsView, .timeView, .waitingView, .searchView, .frame])
        XCTAssertEqual(CanvasAddCommand.offered(projectNote: true)[5], .projectNote)
        XCTAssertEqual(CanvasAddCommand.folder.title, "New Folder\u{2026}")
        XCTAssertEqual(CanvasAddCommand.dayView.title, "New Day View")
    }

    /// A web card and its private twin, which is the same card on the session that is never written to
    /// disk — and they sit together, since choosing between them is one decision.
    func testAPrivateWebCardIsOfferedBesideTheOrdinaryOne() {
        XCTAssertEqual(CanvasAddCommand.web.title, "New Web Card\u{2026}")
        XCTAssertEqual(CanvasAddCommand.privateWeb.title, "New Private Web Card\u{2026}")
        let offered = CanvasAddCommand.offered(projectNote: false)
        XCTAssertEqual(offered.firstIndex(of: .privateWeb), offered.firstIndex(of: .web).map { $0 + 1 })
    }

    /// Every line the board's menu and the header's + draw for this list, in order: what makes a card,
    /// then the views, then the frame — which is alone under its own heading, being the one thing here
    /// that is not a card. This is the menu's contents rather than a copy of the rule, since nothing in
    /// this bundle can build a board to ask one.
    func testTheMenuIsGroupedByWhatEachCommandMakes() {
        XCTAssertEqual(CanvasAddCommand.rows(projectNote: true, tabs: false), [
            .heading(.cards),
            .item(.card), .item(.web), .item(.privateWeb), .item(.file), .item(.folder), .item(.projectNote),
            .heading(.views),
            .item(.dayView), .item(.leftoversView), .item(.comingUpView), .item(.projectsView),
            .item(.timeView), .item(.waitingView), .item(.searchView),
            .heading(.frames),
            .item(.frame),
        ])
        XCTAssertEqual(CanvasAddCommand.Group.cards.title, "Cards")
    }

    /// A board that already has its project note doesn't offer one, and nothing else about the list
    /// moves — the heading above it least of all.
    func testTheCardsHeadingSurvivesTheProjectNoteGoingAway() {
        XCTAssertEqual(CanvasAddCommand.rows(projectNote: false, tabs: false).prefix(6), [
            .heading(.cards),
            .item(.card), .item(.web), .item(.privateWeb), .item(.file), .item(.folder),
        ])
        XCTAssertFalse(CanvasAddCommand.rows(projectNote: false, tabs: false).contains(.item(.projectNote)))
    }

    /// A tile's strip offers what can be a tab: everything but a frame — and the Frames heading goes
    /// with it, since a heading is only written when something follows it.
    func testATabCanBeAnythingButAFrameAndTakesItsHeadingWithIt() {
        let rows = CanvasAddCommand.rows(projectNote: true, tabs: true)
        XCTAssertFalse(rows.contains(.item(.frame)))
        XCTAssertFalse(rows.contains(.heading(.frames)))
        XCTAssertEqual(rows.last, .item(.searchView))
        XCTAssertEqual(rows.filter { if case .heading = $0 { return true } else { return false } },
                       [.heading(.cards), .heading(.views)])
    }
}
