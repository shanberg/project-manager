import XCTest
import AppKit
import PmLib

/// Pasting a picture into a note, and — the part that actually broke — being *allowed* to.
///
/// A plain-text `NSTextView` reports text types and nothing else as readable, so AppKit disabled
/// Edit ▸ Paste for a pasteboard carrying only a picture: the keystroke reached nobody and the note
/// answered a pasted screenshot with a beep. The paste handler was fine the whole time and never ran,
/// which is why these tests assert on validation first and the inserted text second — a test of the
/// handler alone passed all the way through the bug.
@MainActor
final class NoteImagePasteTests: XCTestCase {

    // MARK: fixtures

    /// A pasteboard of this suite's own. The general one is the user's clipboard, and a test run that
    /// wipes what you had copied is a test run that costs you something.
    private func pasteboard(named name: String = #function) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("PMViewTests.\(name)"))
        board.clearContents()
        return board
    }

    /// A real PNG, small enough to be free.
    private var png: Data {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            .representation(using: .png, properties: [:])!
    }

    /// A note in a folder of its own, torn down after the test — a pasted picture is written to disk
    /// beside it, so these tests leave files behind unless the note lives somewhere disposable.
    private func makeNote() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PMViewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let note = folder.appendingPathComponent("Notes.md")
        try "".write(to: note, atomically: true, encoding: .utf8)
        return note
    }

    /// A picture on disk, in a folder torn down after the test.
    private func makeImageFile() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PMViewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("cat.png")
        try png.write(to: file)
        return file
    }

    private var pasteItem: NSMenuItem {
        NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    }

    // MARK: the menu item

    /// The regression. A screenshot is PNG and nothing else — no text flavour to make the standard
    /// item validate — and this is the assertion that failed while pasting one beeped.
    func testPasteIsEnabledForAnImageWithNoTextFlavour() throws {
        let editor = NoteEditor()
        editor.view.noteURL = try makeNote()
        let board = pasteboard()
        board.setData(png, forType: .png)
        editor.view.pasteSource = board

        XCTAssertTrue(editor.view.validateUserInterfaceItem(pasteItem),
                      "a pasteboard holding only a picture should still enable Paste")
    }

    /// The same picture as a browser puts it down — image plus the source URL — which validated all
    /// along. Kept so the fix is understood as widening the case, not inventing it.
    func testPasteStaysEnabledForAnImageWithText() throws {
        let editor = NoteEditor()
        editor.view.noteURL = try makeNote()
        let board = pasteboard()
        board.setData(png, forType: .png)
        board.setString("https://example.com/cat.png", forType: .string)
        editor.view.pasteSource = board

        XCTAssertTrue(editor.view.validateUserInterfaceItem(pasteItem))
    }

    /// A view with no note has nowhere to *write* a picture, so it shouldn't claim the keystroke:
    /// enabling an item whose action then declines is a worse answer than a disabled item.
    ///
    /// Asserted as "we don't claim it" rather than "the item is disabled", like
    /// `testTextIsLeftToTheTextView` below and for the same reason — with the picture declined,
    /// `validateUserInterfaceItem` falls through to `super`, which validates against the **general**
    /// pasteboard rather than `pasteSource`. Whether the item then comes back disabled is a fact about
    /// whatever you last copied, so asserting it made this test pass or fail on the state of the
    /// machine's clipboard. The enabled cases above can assert the item because claiming it is
    /// sufficient on its own; declining is not sufficient to disable it, and never was.
    func testPasteIsNotClaimedWhenThereIsNoNoteToWriteBeside() {
        let editor = NoteEditor()
        editor.view.noteURL = nil
        let board = pasteboard()
        board.setData(png, forType: .png)

        XCTAssertFalse(editor.view.handlesPastedImage(on: board))
    }

    /// An image *file* is claimed with or without a note, which is why `handlesPastedImage` asks about
    /// `noteURL` on one branch and not the other: a file is linked where it already lives, so there is
    /// nothing to write and nowhere it needs to be written.
    func testAnImageFileIsClaimedEvenWithNoNote() throws {
        let editor = NoteEditor()
        editor.view.noteURL = nil
        let board = pasteboard()
        board.writeObjects([try makeImageFile() as NSURL])

        XCTAssertTrue(editor.view.handlesPastedImage(on: board))
    }

    /// Text is not this class's business, and the fix mustn't make it so: a pasteboard of words is
    /// left for `NSTextView` to validate and paste the way it always has.
    ///
    /// Asserted as "we don't claim it" rather than "the item is enabled", because the enabling half of
    /// that is AppKit's — `super.validateUserInterfaceItem` reads the general pasteboard, which these
    /// tests deliberately don't touch.
    func testTextIsLeftToTheTextView() throws {
        let editor = NoteEditor()
        editor.view.noteURL = try makeNote()
        let board = pasteboard()
        board.setString("hello", forType: .string)

        XCTAssertFalse(editor.view.handlesPastedImage(on: board))
    }

    // MARK: what lands in the note

    func testPastingAScreenshotWritesItBesideTheNoteAndEmbedsIt() throws {
        let editor = NoteEditor()
        let note = try makeNote()
        editor.view.noteURL = note
        let board = pasteboard()
        board.setData(png, forType: .png)
        editor.view.pasteSource = board
        editor.reset("before ")

        editor.view.paste(nil)

        XCTAssertTrue(editor.text.hasPrefix("before !["), "expected an embed, got \(editor.text)")
        let attachments = note.deletingLastPathComponent()
            .appendingPathComponent(markdownAttachmentsFolder)
        let written = try FileManager.default.contentsOfDirectory(atPath: attachments.path)
        XCTAssertEqual(written.count, 1, "the picture should be written beside the note")
        XCTAssertTrue(written[0].hasSuffix(".png"))
        XCTAssertTrue(editor.text.contains(markdownAttachmentsFolder),
                      "the embed should point into the attachments folder: \(editor.text)")
    }

    /// TIFF is what an app with nothing better to offer puts down, and it's re-encoded rather than
    /// written: a screen-sized TIFF is tens of megabytes for a picture PNG stores in one.
    func testATiffOnlyPasteLandsAsAPNG() throws {
        let editor = NoteEditor()
        let note = try makeNote()
        editor.view.noteURL = note
        let board = pasteboard()
        board.setData(NSBitmapImageRep(data: png)!.tiffRepresentation!, forType: .tiff)
        editor.view.pasteSource = board

        XCTAssertTrue(editor.view.validateUserInterfaceItem(pasteItem))
        editor.view.paste(nil)

        let attachments = note.deletingLastPathComponent()
            .appendingPathComponent(markdownAttachmentsFolder)
        let written = try FileManager.default.contentsOfDirectory(atPath: attachments.path)
        XCTAssertEqual(written.map { ($0 as NSString).pathExtension }, ["png"])
    }
}
