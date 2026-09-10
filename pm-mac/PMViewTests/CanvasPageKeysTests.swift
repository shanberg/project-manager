import AppKit
import XCTest
@testable import PMViewTests

/// Who a keystroke belongs to while you are standing inside a page.
///
/// The decision is a comparison between a keystroke and a short list, so it is a value rather than
/// anything you need a window for. The half that cannot be asserted here — that a declined key really
/// does reach the page, and that WebKit hands back what the page didn't want — is WebKit's own
/// behaviour, measured in a scratch app rather than guessed at; see `CanvasPageKeys`.
final class CanvasPageKeysTests: XCTestCase {
    private func offers(_ key: String, _ modifiers: NSEvent.ModifierFlags,
                        inPage: Bool = true, handedBack: Bool = false) -> Bool {
        CanvasPageKeys.offersToPage(key: key, modifiers: modifiers,
                                    keyboardIsInAPage: inPage, alreadyOffered: handedBack)
    }

    /// The complaint this exists for: ⌘R in a Figma tile renamed nothing and reloaded the card.
    func testTheKeyFigmaWantsGoesToFigmaFirst() {
        XCTAssertTrue(offers("r", [.command]))
    }

    /// And the reason it is safe to be this generous: PM loses a key only to a page that took it.
    func testAKeyThePageIgnoresComesBackToPM() {
        XCTAssertFalse(offers("r", [.command], handedBack: true),
                       "the second time PM sees the same event, it is PM's")
    }

    func testNothingIsOfferedWhileTheKeyboardIsOnTheBoard() {
        XCTAssertFalse(offers("r", [.command], inPage: false))
        XCTAssertFalse(offers("z", [.command], inPage: false))
    }

    /// Undo inside a canvas app is the app's undo, not the board's.
    func testTheEditingKeysAreOfferedToo() {
        for key in ["z", "d", "e", "[", "]", "+", "-"] {
            XCTAssertTrue(offers(key, [.command]), "⌘\(key) should reach the page")
        }
        XCTAssertTrue(offers("z", [.command, .shift]), "redo is the page's as well")
    }

    /// The way out is never on offer — a page that could eat these could trap you in itself.
    func testTheWayOutIsAlwaysPMs() {
        XCTAssertFalse(offers("q", [.command]), "Quit")
        XCTAssertFalse(offers("w", [.command]), "Close")
        XCTAssertFalse(offers("w", [.command, .option]), "Close All Windows")
        XCTAssertFalse(offers(",", [.command]), "Settings")
        XCTAssertFalse(offers("h", [.command]), "Hide")
        XCTAssertFalse(offers("l", [.command]), "the address bar, which is a browser's own way out")
        XCTAssertFalse(offers("\r", [.command]), "in and out of a workspace")
        XCTAssertFalse(offers("t", [.command]), "New Tab")
        XCTAssertFalse(offers("n", [.command, .shift]), "New Project")
    }

    /// Both numbered rows — the window's tabs and the board's frames — however many there are today.
    func testGoingSomewhereElseIsAlwaysPMs() {
        for digit in 1...9 {
            XCTAssertFalse(offers("\(digit)", [.command]), "⌘\(digit) is a tab")
            XCTAssertFalse(offers("\(digit)", [.control]), "⌃\(digit) is a frame")
        }
        XCTAssertFalse(offers("\t", [.control]), "Next Tab")
        XCTAssertFalse(offers("\t", [.control, .shift]), "Previous Tab")
    }

    /// A digit with a *different* modifier isn't one of those rows and can go to the page.
    func testADigitWithAnotherModifierIsNotATab() {
        XCTAssertTrue(offers("1", [.command, .shift]))
    }

    /// A bare key never reaches the menu bar in the first place, and is the page's already.
    func testUnmodifiedKeysAreNotThisQuestion() {
        XCTAssertFalse(offers("r", []))
        XCTAssertFalse(offers("a", [.shift]))
    }

    /// Caps Lock is a description of the keyboard, not part of the shortcut.
    func testTheKeyboardsOwnFlagsDoNotChangeTheAnswer() {
        XCTAssertFalse(offers("q", [.command, .capsLock]), "still Quit")
        XCTAssertTrue(offers("r", [.command, .capsLock]), "still the page's")
    }

    /// ⇧⌘Z arrives as "Z"; the shift belongs in the modifiers, not in the name of the key.
    func testAKeyIsNamedByItsLetter() throws {
        let shifted = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                       modifierFlags: [.command, .shift],
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       characters: "Z", charactersIgnoringModifiers: "Z",
                                       isARepeat: false, keyCode: 6)
        XCTAssertEqual(CanvasPageKeys.key(of: try XCTUnwrap(shifted)), "z")
    }
}
