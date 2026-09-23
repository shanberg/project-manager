import XCTest
import PmLib

/// What a new card's file is called and where it goes. See `CanvasDocCards`.
final class CanvasDocCardsTests: XCTestCase {
    func testATitleIsTheFirstLineWithWordsOnIt() {
        XCTAssertEqual(CanvasDocCards.title(from: "\n\n  Groceries for Sunday \nmilk"), "Groceries for Sunday")
    }

    func testMarkdownIsTakenOff() {
        XCTAssertEqual(CanvasDocCards.title(from: "## Launch **plan**"), "Launch plan")
        XCTAssertEqual(CanvasDocCards.title(from: "- [ ] call the `vendor`"), "call the vendor")
        XCTAssertEqual(CanvasDocCards.title(from: "> a quote"), "a quote")
        XCTAssertEqual(CanvasDocCards.title(from: "1. first"), "first")
        XCTAssertEqual(CanvasDocCards.title(from: "See [the brief](https://x.test/a) now"), "See the brief now")
        XCTAssertEqual(CanvasDocCards.title(from: "Ask [[W-3 Vendor Contract|Vendor]]"), "Ask Vendor")
    }

    func testCharactersAFilenameOrALinkCannotHoldAreDropped() {
        XCTAssertEqual(CanvasDocCards.title(from: "Q3: what/why? #plan"), "Q3 what why plan")
        XCTAssertEqual(CanvasDocCards.title(from: "..."), nil)
    }

    func testNothingToNameItAfterIsNil() {
        XCTAssertNil(CanvasDocCards.title(from: ""))
        XCTAssertNil(CanvasDocCards.title(from: "  \n# \n"))
        XCTAssertNil(CanvasDocCards.title(from: "**"))
    }

    func testALongLineIsCutAtAWord() throws {
        let title = try XCTUnwrap(CanvasDocCards.title(from: String(repeating: "word ", count: 30)))
        XCTAssertLessThanOrEqual(title.count, 60)
        XCTAssertFalse(title.hasSuffix(" "))
        XCTAssertTrue(title.hasSuffix("word"))
    }

    func testTheDocsFolderIsTheBoardsOwnWhenItIsOne() {
        let inDocs = URL(fileURLWithPath: "/v/P-1 Thing/docs/Thing.canvas")
        XCTAssertEqual(CanvasDocCards.folder(forCanvasAt: inDocs).path, "/v/P-1 Thing/docs")
        let loose = URL(fileURLWithPath: "/v/Boards/Ideas.canvas")
        XCTAssertEqual(CanvasDocCards.folder(forCanvasAt: loose).path, "/v/Boards/docs")
    }

    func testUntitledFilesNeverCollide() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("doc-cards-\(UUID().uuidString)/docs")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let first = try CanvasDocCards.makeUntitled(in: folder)
        let second = try CanvasDocCards.makeUntitled(in: folder)
        XCTAssertEqual(first.lastPathComponent, "Untitled.md")
        XCTAssertEqual(second.lastPathComponent, "Untitled 2.md")
        XCTAssertEqual(try Data(contentsOf: first), Data())
        // A file asked to keep its own name is not in its own way.
        XCTAssertEqual(CanvasDocCards.available("Untitled", in: folder, except: first), first)
        XCTAssertEqual(CanvasDocCards.available("Untitled", in: folder).lastPathComponent, "Untitled 3.md")
    }
}

/// How a card of prose is set, as the file keeps it. See `CanvasTextStyle`.
final class CanvasTextStyleTests: XCTestCase {
    private func node() -> CanvasNode {
        CanvasNode(content: .text("x"), frame: CanvasRect(x: 0, y: 0, width: 100, height: 100))
    }

    func testTheDefaultWritesNothing() {
        var card = node()
        CanvasTextStyle.set(CanvasTextStyle(), on: &card)
        XCTAssertTrue(card.extra.isEmpty)
        XCTAssertEqual(CanvasTextStyle.of(card), CanvasTextStyle())
    }

    func testASettingRoundTripsAndSettingItBackLeavesNoKey() {
        var card = node()
        CanvasTextStyle.set(CanvasTextStyle(lineWidth: .narrow, face: .monospaced), on: &card)
        XCTAssertEqual(CanvasTextStyle.of(card), CanvasTextStyle(lineWidth: .narrow, face: .monospaced))
        CanvasTextStyle.set(CanvasTextStyle(), on: &card)
        XCTAssertTrue(card.extra.isEmpty)
    }

    func testAValueThisBuildDoesntKnowReadsAsTheDefault() {
        var card = node()
        card.extra[CanvasTextStyle.lineWidthKey] = .string("enormous")
        card.extra[CanvasTextStyle.faceKey] = .number(3)
        XCTAssertEqual(CanvasTextStyle.of(card), CanvasTextStyle())
    }

    /// Measured against the face, so it is the character count it claims to be.
    func testTheMeasureIsThatManyCharactersOfTheFace() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        let width = try XCTUnwrap(CanvasTextStyle(lineWidth: .readable).maxColumnWidth(in: font))
        XCTAssertEqual(width, (advance * (78 + MarkdownTextEditor.gutterAdvances)).rounded())
        XCTAssertEqual(width, MarkdownTextEditor.measureWidth)
        XCTAssertNil(CanvasTextStyle(lineWidth: .full).maxColumnWidth(in: font))
    }
}
