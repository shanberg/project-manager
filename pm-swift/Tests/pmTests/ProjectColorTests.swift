import XCTest
import PmLib

final class ProjectColorTests: XCTestCase {

    func testNamesAndHex() {
        XCTAssertEqual(ProjectColor(value: "blue"), .named(.blue))
        XCTAssertEqual(ProjectColor(value: " Teal "), .named(.teal))
        XCTAssertEqual(ProjectColor(value: "#3A7BD5"), .custom("3a7bd5"))
        XCTAssertEqual(ProjectColor(value: "3a7bd5"), .custom("3a7bd5"))
    }

    func testRejectsWhatIsNeither() {
        XCTAssertNil(ProjectColor(value: ""))
        XCTAssertNil(ProjectColor(value: "chartreuse"))
        XCTAssertNil(ProjectColor(value: "#3a7bd"))
        XCTAssertNil(ProjectColor(value: "#3a7bzz"))
    }

    /// Hex is written quoted, since a bare `#` would start a YAML comment — and reads back the same.
    func testRoundTripsThroughFrontmatter() {
        for color in [ProjectColor.named(.indigo), .custom("0a0b0c")] {
            let raw = settingFrontmatterValue(ProjectColor.frontmatterKey, to: color.value, in: "# Title\n")
            XCTAssertEqual(projectColor(rawText: raw), color)
        }
        let raw = settingFrontmatterValue(ProjectColor.frontmatterKey, to: ProjectColor.custom("0a0b0c").value,
                                          in: "---\npm-icon: leaf\n---\n# T\n")
        XCTAssertEqual(raw, "---\npm-icon: leaf\npm-color: \"#0a0b0c\"\n---\n# T\n")
    }

    func testComponents() {
        let color = ProjectColor.custom(red: 1, green: 0.5, blue: 0)
        XCTAssertEqual(color, .custom("ff8000"))
        XCTAssertEqual(color.rgb?.red, 1)
        XCTAssertNil(ProjectColor.named(.red).rgb)
    }
}
