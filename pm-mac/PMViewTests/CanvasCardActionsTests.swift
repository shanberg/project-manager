import XCTest
@testable import PMViewTests

/// Which cards the header's `…` is about — see `CanvasCardActions`. The board that builds the menu can't
/// be hosted here, and this is the half that decides whether the button is there at all.
final class CanvasCardActionsTests: XCTestCase {
    private let kinds: [String: CanvasCardActions.Kind] = [
        "folder-a": .folder, "folder-b": .folder, "note": .text, "site": .link,
    ]
    private func kind(_ id: String) -> CanvasCardActions.Kind? { kinds[id] }

    func testNothingSelectedHasNoMenu() {
        XCTAssertNil(CanvasCardActions.target(focused: nil, selection: [], kind: kind))
    }

    /// A folder picked on the untiled board has its `…` — the case that used to have none.
    func testOneCardOnTheBoardIsItsOwnAnchor() {
        XCTAssertEqual(CanvasCardActions.target(focused: nil, selection: ["folder-a"], kind: kind),
                       .init(ids: ["folder-a"], anchor: "folder-a"))
    }

    /// The tile you are in wins over whatever else is selected, as it did.
    func testAFocusedTileWins() {
        XCTAssertEqual(CanvasCardActions.target(focused: "site", selection: ["note", "folder-a"], kind: kind),
                       .init(ids: ["site"], anchor: "site"))
    }

    /// Several of one kind lead with that kind's commands, which act on all of them.
    func testSeveralOfOneKindKeepTheirOwnCommands() throws {
        let target = try XCTUnwrap(CanvasCardActions.target(focused: nil, selection: ["folder-a", "folder-b"],
                                                            kind: kind))
        XCTAssertEqual(target.ids, ["folder-a", "folder-b"])
        XCTAssertEqual(target.anchor, "folder-a")
    }

    /// A folder and a note together get only what both answer to — no View submenu that looks as
    /// though it applies to the note.
    func testAMixedSelectionLeadsWithNoCardsCommands() throws {
        let target = try XCTUnwrap(CanvasCardActions.target(focused: nil, selection: ["folder-a", "note"],
                                                            kind: kind))
        XCTAssertEqual(target.ids.count, 2)
        XCTAssertNil(target.anchor)
    }

    /// A line in the selection has a menu about lines, not cards.
    func testALineInTheSelectionHasNoCardMenu() {
        XCTAssertNil(CanvasCardActions.target(focused: nil, selection: ["note", "edge"], kind: kind))
    }

    func testTheTooltipSaysTheCount() {
        XCTAssertEqual(CanvasCardActions.help(count: 1, tile: false), "What this card can be told")
        XCTAssertEqual(CanvasCardActions.help(count: 1, tile: true), "What this tile can be told")
        XCTAssertEqual(CanvasCardActions.help(count: 3, tile: false), "What these 3 cards can be told")
    }

    /// New Folder asks only where it has to.
    func testNewFolderLosesItsEllipsisWhereItDoesNotAsk() {
        XCTAssertEqual(CanvasAddCommand.folder.title(knowsFolder: false), "New Folder\u{2026}")
        XCTAssertEqual(CanvasAddCommand.folder.title(knowsFolder: true), "New Folder")
        XCTAssertEqual(CanvasAddCommand.file.title(knowsFolder: true), "New File\u{2026}")
    }
}
