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
}
