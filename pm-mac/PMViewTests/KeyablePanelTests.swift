import XCTest
import AppKit

/// The quick bar's Return keys stay the quick bar's.
///
/// A modified Return that the panel's views decline goes on to the main menu, and the menu's board
/// commands act on the main window — the project window behind the panel. ⌘↩ once switched that
/// window to the canvas instead of adding the task typed into the bar.
@MainActor
final class KeyablePanelTests: XCTestCase {

    private final class KeyRecorder: NSView {
        var received: [NSEvent] = []
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { received.append(event) }
    }

    private func makePanel(keepsReturnKeys: Bool) -> (KeyablePanel, KeyRecorder) {
        TestApp.start()
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.keepsReturnKeys = keepsReturnKeys
        let recorder = KeyRecorder(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        panel.contentView = recorder
        panel.makeFirstResponder(recorder)
        addTeardownBlock { panel.close() }
        return (panel, recorder)
    }

    private func returnKey(_ flags: NSEvent.ModifierFlags, in panel: NSWindow,
                           keyCode: UInt16 = 36) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                       timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                       characters: "\r", charactersIgnoringModifiers: "\r",
                                       isARepeat: false, keyCode: keyCode))
    }

    func testModifiedReturnGoesToTheFirstResponderRatherThanTheMenu() throws {
        let (panel, recorder) = makePanel(keepsReturnKeys: true)
        for flags: NSEvent.ModifierFlags in [.command, [.command, .option], [.command, .shift], .control] {
            XCTAssertTrue(panel.performKeyEquivalent(with: try returnKey(flags, in: panel)),
                          "\(flags) should be claimed before the menu bar sees it")
        }
        XCTAssertEqual(recorder.received.map(\.modifierFlags),
                       [.command, [.command, .option], [.command, .shift], .control])
    }

    func testKeypadEnterToo() throws {
        let (panel, recorder) = makePanel(keepsReturnKeys: true)
        XCTAssertTrue(panel.performKeyEquivalent(with: try returnKey(.command, in: panel, keyCode: 76)))
        XCTAssertEqual(recorder.received.count, 1)
    }

    /// Other keys are the menu's as always: ⌘W still closes, ⌘Q still quits.
    func testOtherKeysAreLeftToTheMenu() throws {
        let (panel, recorder) = makePanel(keepsReturnKeys: true)
        let commandW = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "w",
            charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        XCTAssertFalse(panel.performKeyEquivalent(with: commandW))
        XCTAssertTrue(recorder.received.isEmpty)
    }

    /// Only the panels that ask: the focus panel's ⏎ binding is a key equivalent it still wants.
    func testPanelsThatDontAskAreUnchanged() throws {
        let (panel, recorder) = makePanel(keepsReturnKeys: false)
        XCTAssertFalse(panel.performKeyEquivalent(with: try returnKey(.command, in: panel)))
        XCTAssertTrue(recorder.received.isEmpty)
    }
}
