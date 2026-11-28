import XCTest

/// The sidebar's filter field (docs/spaces.md § Filtering the sidebar): what a query keeps, and how
/// the kept cards are grouped.
final class SidebarFilterTests: XCTestCase {
    private typealias Card = SidebarFilter.Card
    private typealias Layout = SidebarFilter.Layout

    private let cards: [Card] = [
        Card(id: "a", title: "Billing rollover fails on renewal", host: "jira.example.com",
             address: "https://jira.example.com/browse/PM-4127"),
        Card(id: "b", title: "Design review", host: "figma.com", address: "https://figma.com/file/x",
             folderID: "f1", folderLabel: "Research"),
        Card(id: "c", title: "Interview notes", folderID: "f1", folderLabel: "Research"),
        Card(id: "d", title: "Café menu", host: "cafe.example"),
    ]

    func testNothingTypedIsTheSidebarAsItIs() {
        XCTAssertNil(SidebarFilter.run("", cards: cards, layouts: []))
        XCTAssertNil(SidebarFilter.run("   ", cards: cards, layouts: []))
    }

    func testEveryWordMustBeFoundInAnyOrderAndAnyField() throws {
        let result = try XCTUnwrap(SidebarFilter.run("JIRA billing", cards: cards, layouts: []))
        XCTAssertEqual(result.cards, ["a"])
        XCTAssertEqual(try XCTUnwrap(SidebarFilter.run("billing figma", cards: cards, layouts: [])).cards, [])
    }

    func testAccentsAndCaseAside() throws {
        XCTAssertEqual(try XCTUnwrap(SidebarFilter.run("cafe", cards: cards, layouts: [])).cards, ["d"])
    }

    func testAFolderNameFindsWhatIsInItUnderItsLabel() throws {
        let result = try XCTUnwrap(SidebarFilter.run("research", cards: cards, layouts: []))
        XCTAssertEqual(result.sections, [.init(folderID: "f1", label: "Research", cards: ["b", "c"])])
    }

    func testLooseCardsComeFirstThenFoldersWhereTheirFirstCardCame() throws {
        let mixed = [cards[1], cards[0], cards[2]]
        let result = try XCTUnwrap(SidebarFilter.run("e", cards: mixed, layouts: []))
        XCTAssertEqual(result.sections.map(\.folderID), [nil, "f1"])
        XCTAssertEqual(result.cards, ["a", "b", "c"])
    }

    func testWhatACardSaysCountsThoughItsNameDoesNot() throws {
        let result = try XCTUnwrap(SidebarFilter.run("quarterly", cards: cards, layouts: [], says: ["c"]))
        XCTAssertEqual(result.cards, ["c"])
    }

    func testACardGivenTwiceIsKeptOnce() throws {
        let result = try XCTUnwrap(SidebarFilter.run("billing", cards: cards + [cards[0]], layouts: []))
        XCTAssertEqual(result.cards, ["a"])
    }

    func testALayoutIsKeptByItsNameOrByACardItShows() throws {
        let layouts = [Layout(name: "Triage", cards: ["a"]), Layout(name: "Reading", cards: ["c"])]
        XCTAssertEqual(try XCTUnwrap(SidebarFilter.run("triage", cards: cards, layouts: layouts)).layouts, ["Triage"])
        XCTAssertEqual(try XCTUnwrap(SidebarFilter.run("interview", cards: cards, layouts: layouts)).layouts, ["Reading"])
    }

    func testNoMatchesIsEmptyNotNil() throws {
        XCTAssertTrue(try XCTUnwrap(SidebarFilter.run("zzz", cards: cards, layouts: [])).isEmpty)
    }
}
