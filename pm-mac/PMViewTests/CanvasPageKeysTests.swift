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

    /// Reload is offered like anything else: a page that answers ⌘R gets it.
    func testReloadGoesToThePageFirst() {
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

    // MARK: Twice, not once

    /// The complaint this began with: Figma in a tile leaves ⌘R alone, so it came back and reloaded.
    func testReloadHandedBackWaitsForASecondPress() {
        XCTAssertTrue(CanvasPageKeys.asksForASecondPress(key: "r", modifiers: [.command]))
        XCTAssertTrue(CanvasPageKeys.asksForASecondPress(key: "r", modifiers: [.command, .capsLock]))
    }

    /// Everything else a page declines is answered at once, as it always was.
    func testOnlyReloadWaits() {
        XCTAssertFalse(CanvasPageKeys.asksForASecondPress(key: "r", modifiers: [.command, .shift]))
        XCTAssertFalse(CanvasPageKeys.asksForASecondPress(key: "z", modifiers: [.command]))
        XCTAssertFalse(CanvasPageKeys.asksForASecondPress(key: "[", modifiers: [.command]))
    }

    /// The hint's name for the item comes from the menu bar's own item, so it must find the right one.
    func testAKeystrokeFindsItsMenuItem() {
        let reload = NSMenuItem(title: "Reload Page", action: nil, keyEquivalent: "r")
        XCTAssertTrue(CanvasPageKeys.matches(reload, key: "r", modifiers: [.command]))
        XCTAssertFalse(CanvasPageKeys.matches(reload, key: "r", modifiers: [.command, .shift]))
        XCTAssertFalse(CanvasPageKeys.matches(reload, key: "e", modifiers: [.command]))
        let noKey = NSMenuItem(title: "Back to Card's Address", action: nil, keyEquivalent: "")
        XCTAssertFalse(CanvasPageKeys.matches(noKey, key: "", modifiers: [.command]))
    }

    func testTheHintWritesTheKeyTheWayTheMenuBarDoes() {
        XCTAssertEqual(CanvasPageKeys.glyphs(key: "r", modifiers: [.command]), "⌘R")
        XCTAssertEqual(CanvasPageKeys.glyphs(key: "z", modifiers: [.shift, .command]), "⇧⌘Z")
        XCTAssertEqual(CanvasPageKeys.glyphs(key: "r", modifiers: [.command, .capsLock]), "⌘R")
    }
}

/// The double tap, on a window short enough to wait out.
///
/// What can go wrong — one press that reloads, two that don't, a reload twice, a second press in
/// another page that reloads the wrong one — is all in the counting, so it is asserted here. That a
/// held key's repeats never arrive as presses is the menu bar's job; see `PageFirstMenu`.
@MainActor
final class DoubleTapTests: XCTestCase {
    private var shown: [String?] = []
    private var confirmed = 0
    private let hint = "Press ⌘R again to Reload Page"
    private let page = ObjectIdentifier(NSObject.self)
    private let otherPage = ObjectIdentifier(NSView.self)

    private func makeTap() -> DoubleTap {
        DoubleTap(window: 0.15) { [weak self] in self?.shown.append($0) }
    }

    private func press(_ tap: DoubleTap, in page: ObjectIdentifier? = nil) {
        tap.pressed(hint: hint, in: page ?? self.page) { self.confirmed += 1 }
    }

    private func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    override func setUp() {
        shown = []
        confirmed = 0
    }

    /// The accident: pressed once.
    func testOnePressOnlyShowsTheHint() {
        let tap = makeTap()
        press(tap)
        XCTAssertEqual(confirmed, 0)
        XCTAssertEqual(shown, [hint])
        wait(0.4)
        XCTAssertEqual(confirmed, 0, "still nothing once the hint has gone")
        XCTAssertEqual(shown, [hint, nil], "shown, then gone on its own")
    }

    func testASecondPressReloadsOnce() {
        let tap = makeTap()
        press(tap)
        wait(0.05)
        press(tap)
        XCTAssertEqual(confirmed, 1)
        XCTAssertEqual(shown, [hint, nil], "the hint goes when it's answered")
        wait(0.4)
        XCTAssertEqual(confirmed, 1)
        XCTAssertEqual(shown, [hint, nil], "and the expired timer doesn't hide it a second time")
    }

    /// The press after a reload is a new first press, not a third that reloads again.
    func testAThirdPressStartsOver() {
        let tap = makeTap()
        press(tap)
        press(tap)
        press(tap)
        XCTAssertEqual(confirmed, 1)
        XCTAssertEqual(shown, [hint, nil, hint])
    }

    func testASecondPressAfterTheHintHasGoneIsAFirstPress() {
        let tap = makeTap()
        press(tap)
        wait(0.3)
        press(tap)
        XCTAssertEqual(confirmed, 0)
        XCTAssertEqual(shown, [hint, nil, hint])
    }

    /// ⌘R in one tile, a click into another, ⌘R again: that page never got its first press.
    func testASecondPressInAnotherPageIsAFirstPress() {
        let tap = makeTap()
        press(tap, in: page)
        press(tap, in: otherPage)
        XCTAssertEqual(confirmed, 0)
        press(tap, in: otherPage)
        XCTAssertEqual(confirmed, 1, "the other page's own second press does count")
    }
}

/// Where the hint appears, asserted as a frame rather than as `isVisible`, which is true wherever the
/// panel happens to be.
@MainActor
final class KeyHintTests: XCTestCase {
    func testTheHintSitsOverTheMiddleOfTheWindowAndIgnoresTheMouse() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let hint = KeyHint()
        hint.show("Press ⌘R again to Reload Page", over: window)
        let panel = try XCTUnwrap(hint.panel)
        XCTAssertTrue(panel.parent === window, "rides along with the window")
        XCTAssertEqual(panel.frame.midX, window.frame.midX, accuracy: 1)
        XCTAssertEqual(panel.frame.midY, window.frame.midY, accuracy: 1)
        XCTAssertLessThan(panel.frame.width, window.frame.width)
        XCTAssertGreaterThan(panel.frame.width, 200, "wide enough for the sentence, not collapsed")
        XCTAssertTrue(panel.ignoresMouseEvents, "never takes a click meant for the page")

        hint.hide()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(panel.parent, "gone once it has faded")
    }
}
