import XCTest
@testable import PmLib

/// Reading a note that Obsidian wrote: its embed syntax, and finding the file it names.
///
/// The fixture is a PARA vault the shape of a real one — a numbered project under `active/`, the note
/// down in the project's `docs/` — because the distance between the note and the vault root is exactly
/// what a vault-relative path has to cross.
final class ObsidianEmbedTests: XCTestCase {
    private var vault: URL!
    private var note: URL!

    override func setUpWithError() throws {
        vault = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm-vault-\(UUID().uuidString)")
        note = vault.appendingPathComponent("active/W-1 Site/docs/Notes - Site.md")
        for folder in [".obsidian", "attachments", "active/W-1 Site/docs/attachments", "z_assets"] {
            try FileManager.default.createDirectory(at: vault.appendingPathComponent(folder),
                                                    withIntermediateDirectories: true)
        }
        try "".write(to: note, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vault)
    }

    private func put(_ relativePath: String) throws -> URL {
        let url = vault.appendingPathComponent(relativePath)
        try Data([0x89]).write(to: url)
        return url
    }

    private func setAttachmentFolder(_ value: String) throws {
        let json = try JSONSerialization.data(withJSONObject: ["attachmentFolderPath": value])
        try json.write(to: vault.appendingPathComponent(".obsidian/app.json"))
    }

    // MARK: the syntax

    func testAWikilinkEmbedIsFound() {
        let images = markdownImages(in: "![[Pasted image 20260827.png]]")
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images[0].destination, "Pasted image 20260827.png")
        XCTAssertEqual(images[0].alt, "Pasted image 20260827.png", "the filename is all there is to say")
        XCTAssertNil(images[0].width)
    }

    func testTheSizeAfterThePipeIsAWidthNotAnAlias() {
        XCTAssertEqual(markdownImages(in: "![[shot.png|300]]")[0].width, 300)
        XCTAssertEqual(markdownImages(in: "![[shot.png|300x200]]")[0].width, 300)
        XCTAssertEqual(markdownImages(in: "![[shot.png|300]]")[0].destination, "shot.png")
        // A wikilink *link* has an alias there and is not an embed at all.
        XCTAssertTrue(markdownImages(in: "[[Design Notes|the design]]").isEmpty)
    }

    func testBothSyntaxesInOneNoteComeBackInSourceOrder() {
        let text = "![[first.png]] then ![second](second.png)"
        XCTAssertEqual(markdownImages(in: text).map(\.destination), ["first.png", "second.png"])
    }

    func testAWikilinkEmbedBecomesAPictureSegment() {
        XCTAssertEqual(markdownNoteSegments(in: "notes\n\n![[shot.png|300]]"), [
            .prose("notes"),
            .image(destination: "shot.png", alt: "shot.png", width: 300),
        ])
    }

    func testTheEmbedsTargetReadsAndItsSizeDims() {
        let t = "![[shot.png|300]]"
        let spans = markdownSpans(in: t)
        let content = spans.filter { $0.kind == .wikilink }.map { String(t[$0.range]) }
        let syntax = spans.filter { $0.kind == .syntax }.map { String(t[$0.range]) }
        XCTAssertEqual(content, ["shot.png"], "the file is what reads, not the width")
        XCTAssertTrue(syntax.contains("300"))
        XCTAssertTrue(syntax.contains("!"))
        // As everywhere else, the markers may not overlap — the read view deletes them.
        let ranges = spans.filter { $0.kind == .syntax }.map(\.range)
        XCTAssertEqual(Set(ranges).count, ranges.count)
        XCTAssertEqual(syntax.joined().count + "shot.png".count, t.count)
    }

    func testAPlainWikilinkStillShowsItsAlias() {
        let t = "see [[Design Notes|the design]]"
        XCTAssertEqual(markdownSpans(in: t).filter { $0.kind == .wikilink }.map { String(t[$0.range]) },
                       ["the design"])
    }

    // MARK: finding the file

    func testAFileBesideTheNoteIsFoundByName() throws {
        let file = try put("active/W-1 Site/docs/Beside.png")
        XCTAssertEqual(resolveNoteReference("Beside.png", noteAt: note)?.path, file.path)
    }

    func testAPathRelativeToTheVaultRootResolvesFromDeepInIt() throws {
        // Obsidian's "absolute path in vault" link format, read from a note three folders down.
        let file = try put("attachments/Pasted image.png")
        XCTAssertEqual(resolveNoteReference("attachments/Pasted%20image.png", noteAt: note)?.path, file.path)
    }

    func testABareNameInTheVaultsOwnAttachmentFolderIsFound() throws {
        try setAttachmentFolder("z_assets")
        let file = try put("z_assets/Pasted image.png")
        XCTAssertEqual(resolveNoteReference("Pasted image.png", noteAt: note)?.path, file.path,
                       "a vault that keeps attachments somewhere unusual says so, and we read it")
    }

    func testASubfolderBesideTheNoteIsFound() throws {
        try setAttachmentFolder("./attachments")
        let file = try put("active/W-1 Site/docs/attachments/In a subfolder.png")
        XCTAssertEqual(resolveNoteReference("In a subfolder.png", noteAt: note)?.path, file.path)
    }

    func testTheNearestCopyWins() throws {
        // Same name in two places: the one beside the note is the one the note means.
        _ = try put("attachments/shot.png")
        let near = try put("active/W-1 Site/docs/shot.png")
        XCTAssertEqual(resolveNoteReference("shot.png", noteAt: note)?.path, near.path)
    }

    func testChangingTheVaultSettingIsPickedUp() throws {
        // The answer is cached so a redraw doesn't re-read the file; it's keyed by the file's own
        // modification date, so editing the setting in Obsidian takes effect without restarting PM.
        try setAttachmentFolder("z_assets")
        let inAssets = try put("z_assets/shot.png")
        XCTAssertEqual(resolveNoteReference("shot.png", noteAt: note)?.path, inAssets.path)

        try FileManager.default.removeItem(at: inAssets)
        try setAttachmentFolder("attachments")
        let inAttachments = try put("attachments/shot.png")
        XCTAssertEqual(resolveNoteReference("shot.png", noteAt: note)?.path, inAttachments.path)
    }

    func testAMissingFileResolvesToNothing() {
        XCTAssertNil(resolveNoteReference("nope.png", noteAt: note))
        XCTAssertNil(resolveNoteReference("", noteAt: note))
    }

    func testTheVaultRootIsTheFolderHoldingDotObsidian() {
        XCTAssertEqual(obsidianVaultRoot(for: note)?.path, vault.standardizedFileURL.path)
    }

    func testANoteOutsideAnyVaultStillResolvesBesideItself() throws {
        let loose = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm-loose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: loose) }
        let looseNote = loose.appendingPathComponent("Notes.md")
        try "".write(to: looseNote, atomically: true, encoding: .utf8)
        let file = loose.appendingPathComponent("shot.png")
        try Data([0x89]).write(to: file)

        XCTAssertNil(obsidianVaultRoot(for: looseNote))
        XCTAssertEqual(resolveNoteReference("shot.png", noteAt: looseNote)?.path, file.path)
    }
}
