import XCTest
import PmLib

final class ProjectIconTests: XCTestCase {
    // MARK: Reading a value

    func testSymbolNames() {
        XCTAssertEqual(ProjectIcon(value: "leaf.fill"), .symbol("leaf.fill"))
        XCTAssertEqual(ProjectIcon(value: "person.2"), .symbol("person.2"))
        XCTAssertEqual(ProjectIcon(value: "\"globe\""), .symbol("globe"))
    }

    func testEmoji() {
        XCTAssertEqual(ProjectIcon(value: "🌿"), .emoji("🌿"))
        // Variation-selector and ZWJ sequences are one grapheme, so still one emoji.
        XCTAssertEqual(ProjectIcon(value: "🛠️"), .emoji("🛠️"))
        XCTAssertEqual(ProjectIcon(value: "👩‍💻"), .emoji("👩‍💻"))
    }

    func testRejectsWhatIsNeither() {
        XCTAssertNil(ProjectIcon(value: ""))
        XCTAssertNil(ProjectIcon(value: "   "))
        XCTAssertNil(ProjectIcon(value: "Leaf Fill"))
        XCTAssertNil(ProjectIcon(value: "🌿🌿"))
        // A bare digit has the Emoji property but isn't drawn as one — it's a symbol-shaped name.
        XCTAssertEqual(ProjectIcon(value: "1"), .symbol("1"))
    }

    // MARK: Frontmatter

    func testReadsIconFromFrontmatter() {
        let raw = "---\ntags: work\npm-icon: leaf.fill\n---\n# Website Refresh\n"
        XCTAssertEqual(projectIcon(rawText: raw), .symbol("leaf.fill"))
    }

    func testIgnoresTheKeyOutsideFrontmatter() {
        XCTAssertNil(projectIcon(rawText: "# T\n\npm-icon: leaf.fill\n"))
        // An unclosed block isn't frontmatter.
        XCTAssertNil(projectIcon(rawText: "---\npm-icon: leaf.fill\n# T\n"))
    }

    func testSettingAddsABlockWhenThereIsNone() {
        let raw = "# T\n\n## Sessions\n"
        XCTAssertEqual(settingFrontmatterValue("pm-icon", to: "🌿", in: raw),
                       "---\npm-icon: 🌿\n---\n# T\n\n## Sessions\n")
    }

    func testSettingReplacesAndKeepsOtherKeys() {
        let raw = "---\ntags: work\npm-icon: leaf.fill\naliases: [WR]\n---\n# T\n"
        XCTAssertEqual(settingFrontmatterValue("pm-icon", to: "star.fill", in: raw),
                       "---\ntags: work\npm-icon: star.fill\naliases: [WR]\n---\n# T\n")
    }

    func testSettingAppendsToAnExistingBlock() {
        let raw = "---\ntags: work\n---\n# T\n"
        XCTAssertEqual(settingFrontmatterValue("pm-icon", to: "globe", in: raw),
                       "---\ntags: work\npm-icon: globe\n---\n# T\n")
    }

    func testClearingKeepsOtherKeys() {
        let raw = "---\ntags: work\npm-icon: leaf.fill\n---\n# T\n"
        XCTAssertEqual(settingFrontmatterValue("pm-icon", to: nil, in: raw), "---\ntags: work\n---\n# T\n")
    }

    /// Trying an icon and going back to the ring leaves the file byte-for-byte as it was.
    func testClearingTheOnlyKeyRemovesTheBlock() {
        let raw = "# T\n\n## Sessions\n"
        let set = settingFrontmatterValue("pm-icon", to: "leaf.fill", in: raw)
        XCTAssertEqual(settingFrontmatterValue("pm-icon", to: nil, in: set), raw)
    }

    func testClearingWhenAbsentChangesNothing() {
        let raw = "---\ntags: work\n---\n# T\n"
        XCTAssertEqual(settingFrontmatterValue("pm-icon", to: nil, in: raw), raw)
        XCTAssertEqual(settingFrontmatterValue("pm-icon", to: nil, in: "# T\n"), "# T\n")
    }

    // MARK: Whole-file writes

    func testCarryingFrontmatterRestoresTheBlock() {
        let original = "---\npm-icon: leaf.fill\n---\n# Old\n"
        XCTAssertEqual(carryingFrontmatter(from: original, into: "# New\n"),
                       "---\npm-icon: leaf.fill\n---\n# New\n")
        XCTAssertEqual(carryingFrontmatter(from: "# Old\n", into: "# New\n"), "# New\n")
    }

    /// The fallback every detail edit takes when it can't splice — it must not strip the icon.
    func testWriteNotesFileKeepsFrontmatter() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Notes - T.md").path
        try "---\npm-icon: 🌿\n---\n# T\n\n## Sessions\n".write(toFile: path, atomically: true, encoding: .utf8)

        var notes = try readNotesFile(notesPath: path)
        notes.summary = "Rewritten from the model."
        try writeNotesFile(notesPath: path, notes: notes)

        let written = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(written.hasPrefix("---\npm-icon: 🌿\n---\n# T"), written)
        XCTAssertEqual(projectIcon(rawText: written), .emoji("🌿"))
        XCTAssertEqual(try readNotesFile(notesPath: path).summary, "Rewritten from the model.")
    }
}
