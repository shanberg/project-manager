import XCTest
@testable import PmLib

/// Images in a note: locating the embeds, cutting a note into the pieces a read view draws, and
/// deciding where a pasted image is written.
final class MarkdownImagesTests: XCTestCase {

    // MARK: locating embeds

    func testFindsAnEmbedAndItsParts() {
        let text = "before\n![a shot](attachments/shot.png)\nafter"
        let images = markdownImages(in: text)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images[0].alt, "a shot")
        XCTAssertEqual(images[0].destination, "attachments/shot.png")
        XCTAssertEqual(String(text[images[0].range]), "![a shot](attachments/shot.png)")
    }

    func testAnEmptyAltIsStillAnEmbed() {
        // What a paste from a tool with no name for the picture writes.
        let images = markdownImages(in: "![](attachments/shot.png)")
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images[0].alt, "")
    }

    func testAPlainLinkIsNotAnEmbed() {
        XCTAssertTrue(markdownImages(in: "[spec](spec.pdf)").isEmpty)
    }

    // MARK: what counts as an image

    func testImagePathsAreRecognizedCaseInsensitively() {
        XCTAssertTrue(isMarkdownImagePath("attachments/Shot.PNG"))
        XCTAssertTrue(isMarkdownImagePath("/tmp/a.heic"))
        XCTAssertFalse(isMarkdownImagePath("docs/spec.pdf"))
        XCTAssertFalse(isMarkdownImagePath("no-extension"))
    }

    // MARK: segmenting a note

    func testANoteWithNoImagesIsOneSegment() {
        XCTAssertEqual(markdownNoteSegments(in: "just **prose**"), [.prose("just **prose**")])
    }

    func testProseAroundAnImageSplitsAndKeepsItsMarkdown() {
        let text = "## Standup\n\n![shot](attachments/a.png)\n\n- shipped it"
        XCTAssertEqual(markdownNoteSegments(in: text), [
            .prose("## Standup"),
            .image(destination: "attachments/a.png", alt: "shot"),
            .prose("- shipped it"),
        ])
    }

    func testAnImageMidSentenceStillBecomesItsOwnSegment() {
        XCTAssertEqual(markdownNoteSegments(in: "see ![it](a.png) here"), [
            .prose("see"),
            .image(destination: "a.png", alt: "it"),
            .prose("here"),
        ])
    }

    func testTwoImagesInARowLeaveNoEmptyProseBetweenThem() {
        let text = "![](a.png)\n\n![](b.png)\n"
        XCTAssertEqual(markdownNoteSegments(in: text), [
            .image(destination: "a.png", alt: ""),
            .image(destination: "b.png", alt: ""),
        ])
    }

    func testAnEmbedPointingAtSomethingThatIsntAnImageStaysInTheProse() {
        // `![spec](spec.pdf)` is a link someone typed a stray `!` in front of. There's nothing to draw,
        // so it belongs to the text renderer, which already knows what to do with it.
        XCTAssertEqual(markdownNoteSegments(in: "![spec](spec.pdf)"), [.prose("![spec](spec.pdf)")])
    }

    // MARK: naming and writing

    func testPastedImageNameIsTheTimestamp() {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 27
        components.hour = 14; components.minute = 32; components.second = 10
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: components)!
        // Formatted in the local zone, so the name matches the clock the paste happened on.
        let expected = { () -> String in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMddHHmmss"
            return "Pasted image \(f.string(from: date))"
        }()
        XCTAssertEqual(pastedImageBaseName(at: date), expected)
    }

    func testASecondPasteInTheSameSecondGetsItsOwnFile() {
        let folder = URL(fileURLWithPath: "/vault/docs/attachments")
        let taken: Set<String> = ["/vault/docs/attachments/Pasted image 1.png"]
        XCTAssertEqual(availableAttachmentURL(base: "Pasted image 1", ext: "png", in: folder,
                                              exists: { taken.contains($0.path) }).lastPathComponent,
                       "Pasted image 1-1.png")
    }

    func testSavingWritesBesideTheNoteAndEmbedsRelatively() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm-attachments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let note = tmp.appendingPathComponent("Notes - Site.md")
        let data = Data([0x89, 0x50, 0x4E, 0x47])
        let file = try saveNoteAttachment(data, ext: "png", baseName: "Pasted image 1", forNoteAt: note)

        XCTAssertEqual(file.deletingLastPathComponent().lastPathComponent, markdownAttachmentsFolder)
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(markdownImageEmbed(for: file, relativeTo: note, alt: "Pasted image"),
                       "![Pasted image](attachments/Pasted%20image%201.png)")
    }

    // MARK: Copying a file that is already one

    /// A file dropped on a board from outside the vault, copied in: same folder as a pasted image,
    /// but keeping its own name, which is most of what its card will show.
    func testCopyingKeepsTheFilesOwnNameAndLeavesTheOriginal() throws {
        let (vault, outside) = try twoFolders()
        let note = vault.appendingPathComponent("Boards/board.canvas")
        let original = outside.appendingPathComponent("Spec.md")
        try "the spec".write(to: original, atomically: true, encoding: .utf8)

        let copied = try copyNoteAttachment(original, forNoteAt: note)

        XCTAssertEqual(copied.lastPathComponent, "Spec.md")
        XCTAssertEqual(copied.deletingLastPathComponent().lastPathComponent, markdownAttachmentsFolder)
        XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "the spec")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path),
                      "the file was moved rather than copied")
    }

    /// The same file twice is two files. Overwriting would quietly change what an existing card on the
    /// board is pointing at, which is the one outcome worth ruling out here.
    func testCopyingTheSameNameTwiceDoesNotOverwrite() throws {
        let (vault, outside) = try twoFolders()
        let note = vault.appendingPathComponent("Boards/board.canvas")
        let first = outside.appendingPathComponent("Spec.md")
        try "first".write(to: first, atomically: true, encoding: .utf8)
        let second = outside.appendingPathComponent("elsewhere/Spec.md")
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try "second".write(to: second, atomically: true, encoding: .utf8)

        let one = try copyNoteAttachment(first, forNoteAt: note)
        let two = try copyNoteAttachment(second, forNoteAt: note)

        XCTAssertEqual(one.lastPathComponent, "Spec.md")
        XCTAssertEqual(two.lastPathComponent, "Spec-1.md")
        XCTAssertEqual(try String(contentsOf: one, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: two, encoding: .utf8), "second")
    }

    /// A file with no extension — a `Makefile`, a folder someone dragged in — must not land with a
    /// trailing dot on the end of its name.
    func testAFileWithNoExtensionKeepsItsBareName() throws {
        let (vault, outside) = try twoFolders()
        let note = vault.appendingPathComponent("Boards/board.canvas")
        let makefile = outside.appendingPathComponent("Makefile")
        try "all:".write(to: makefile, atomically: true, encoding: .utf8)

        XCTAssertEqual(try copyNoteAttachment(makefile, forNoteAt: note).lastPathComponent, "Makefile")
        XCTAssertEqual(try copyNoteAttachment(makefile, forNoteAt: note).lastPathComponent, "Makefile-1")
    }

    private func twoFolders() throws -> (vault: URL, outside: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm-copy-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("Vault")
        let outside = root.appendingPathComponent("Downloads")
        for folder in [vault.appendingPathComponent("Boards"), outside] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return (vault, outside)
    }
}
