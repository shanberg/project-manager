import AppKit
import SwiftUI
import XCTest

/// A note that gets shorter repaints what it vacated. See `TokenLayoutManager.laidOutBottom`.
///
/// The pixels themselves are the window server's, which a test without Screen Recording can't read —
/// `cacheDisplay` draws afresh and `CALayer.render` comes back blank for AppKit's backing stores — so
/// what is asserted is the repaint being asked for, in the real editor hosted as a card hosts it.
@MainActor
final class NoteEditorRedrawTests: XCTestCase {
    final class Box { var text: String; init(_ t: String) { text = t } }

    private var window: NSWindow!
    private var view: ShortcutTextView!
    private var manager: TokenLayoutManager { view.layoutManager as! TokenLayoutManager }

    override func setUp() async throws {
        TestApp.start()
        let size = NSSize(width: 320, height: 240)
        let box = Box("one\ntwo\nthree\nfour")
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .windowBackgroundColor
        let ground = NSView(frame: NSRect(origin: .zero, size: size))
        ground.wantsLayer = true
        var editor = MarkdownTextEditor(text: Binding(get: { box.text }, set: { box.text = $0 }))
        editor.baseFont = .monospacedSystemFont(ofSize: 20, weight: .regular)
        let hosting = NSHostingView(rootView: editor)
        hosting.frame = ground.bounds
        ground.addSubview(hosting)
        window.contentView = ground
        window.orderBack(nil)
        settle()
        view = try XCTUnwrap(find(in: ground))
    }

    override func tearDown() async throws { window.orderOut(nil) }

    private func find(in view: NSView) -> ShortcutTextView? {
        if let hit = view as? ShortcutTextView { return hit }
        for sub in view.subviews { if let hit = find(in: sub) { return hit } }
        return nil
    }

    private func settle() {
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.displayIfNeeded()
    }

    func testDeletingTheFirstLineRepaints() {
        let before = manager.repaintsAfterShrinking
        view.setSelectedRange(NSRange(location: 0, length: 4))
        view.deleteBackward(nil)
        settle()
        XCTAssertEqual(view.string, "two\nthree\nfour")
        XCTAssertGreaterThan(manager.repaintsAfterShrinking, before)
    }

    func testJoiningTheLastLineRepaints() {
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        for _ in 0..<4 { view.deleteBackward(nil) }
        settle()
        let before = manager.repaintsAfterShrinking
        view.deleteBackward(nil)   // the newline: "four"'s line is gone
        settle()
        XCTAssertEqual(view.string, "one\ntwo\nthree")
        XCTAssertGreaterThan(manager.repaintsAfterShrinking, before)
    }

    /// Negative control: an edit that doesn't change the height costs nothing extra.
    func testTypingWithinALineDoesNotRepaintEverything() {
        let before = manager.repaintsAfterShrinking
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.insertText("s", replacementRange: view.selectedRange())
        view.deleteBackward(nil)
        settle()
        XCTAssertEqual(manager.repaintsAfterShrinking, before)
    }
}
