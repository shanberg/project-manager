import XCTest
import PmLib

final class ProjectTextureTests: XCTestCase {

    func testNamesAndImages() {
        XCTAssertEqual(ProjectTexture(value: "weave"), .named(.weave))
        XCTAssertEqual(ProjectTexture(value: " Checker "), .named(.checker))
        XCTAssertEqual(ProjectTexture(value: "attachments/Linen.png"), .image("attachments/Linen.png"))
        XCTAssertEqual(ProjectTexture(value: "attachments/My Photo #2.JPG"), .image("attachments/My Photo #2.JPG"))
    }

    func testRejectsWhatIsNeither() {
        XCTAssertNil(ProjectTexture(value: ""))
        XCTAssertNil(ProjectTexture(value: "plaid"))
        XCTAssertNil(ProjectTexture(value: "attachments/notes.md"))
        XCTAssertNil(ProjectTexture(value: "/Users/me/linen.png"))
        XCTAssertNil(ProjectTexture(value: "~/linen.png"))
    }

    /// A path is written quoted — a `#` in a file name would otherwise start a YAML comment — and reads
    /// back the same.
    func testRoundTripsThroughFrontmatter() {
        for texture in [ProjectTexture.named(.hatch), .image("attachments/a #1: b.png")] {
            let raw = settingFrontmatterValue(ProjectTexture.frontmatterKey, to: texture.value, in: "# Title\n")
            XCTAssertEqual(projectTexture(rawText: raw), texture)
        }
        let raw = settingFrontmatterValue(ProjectTexture.frontmatterKey, to: ProjectTexture.named(.dots).value,
                                          in: "---\npm-color: teal\n---\n# T\n")
        XCTAssertEqual(raw, "---\npm-color: teal\npm-texture: dots\n---\n# T\n")
    }

    func testImageResolvesBesideTheNotes() {
        let texture = ProjectTexture.image("attachments/Linen.png")
        XCTAssertEqual(texture.imageURL(notesPath: "/p/W-001 Thing/docs/Notes - Thing.md")?.path,
                       "/p/W-001 Thing/docs/attachments/Linen.png")
        XCTAssertNil(ProjectTexture.named(.grid).imageURL(notesPath: "/p/n.md"))
    }

    func testStyleDefaultsClampsAndWritesOnlyWhatDiffers() {
        XCTAssertEqual(projectTextureStyle(rawText: "# T\n"), .standard)
        let raw = "---\npm-texture: dots\npm-texture-reach: LONG\npm-texture-strength: x\npm-texture-pixel: 9\n---\n"
        XCTAssertEqual(projectTextureStyle(rawText: raw), ProjectTextureStyle(reach: .long, strength: 15, pixel: 3))

        let style = ProjectTextureStyle(reach: .short, strength: 15, pixel: 3, tile: 48)
        let written = settingProjectTexture(.named(.checker), style: style, in: "# T\n")
        // No tile line: a built-in pattern has no tile size to keep.
        XCTAssertEqual(written, "---\npm-texture: checker\npm-texture-reach: short\npm-texture-pixel: 3\n---\n# T\n")
        let image = settingProjectTexture(.image("attachments/a.png"), style: style, in: "# T\n")
        XCTAssertEqual(projectTextureStyle(rawText: image), style)
        // Clearing the texture takes its style with it.
        XCTAssertEqual(settingProjectTexture(nil, style: style, in: image), "# T\n")
    }

    /// Reach was a percentage for a while; those files read as the nearest name.
    func testReachReadsTheOldPercentages() {
        XCTAssertEqual(ProjectTextureStyle.Reach(value: "25"), .short)
        XCTAssertEqual(ProjectTextureStyle.Reach(value: "50"), .medium)
        XCTAssertEqual(ProjectTextureStyle.Reach(value: "90"), .long)
        XCTAssertNil(ProjectTextureStyle.Reach(value: "far"))
    }
}
