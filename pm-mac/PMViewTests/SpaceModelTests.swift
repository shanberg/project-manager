import XCTest

/// What a space records beside its canvas. docs/spaces.md § Spaces.
final class SpaceModelTests: XCTestCase {
    func testASpaceStartsUntitled() {
        let space = Space(color: "blue")
        XCTAssertEqual(space.name, "")
        XCTAssertEqual(space.title, "Untitled Space")
        XCTAssertEqual(Space(name: "Music", color: "pink").title, "Music")
    }

    func testItsCanvasIsNamedForItsID() {
        let folder = URL(fileURLWithPath: "/tmp/spaces")
        let space = Space(id: "ABC", color: "blue")
        XCTAssertEqual(space.canvas(in: folder).path, "/tmp/spaces/ABC.canvas")
        var file = SpaceFile()
        file.spaces = [space]
        XCTAssertEqual(file.space(forCanvas: URL(fileURLWithPath: "/tmp/spaces/./ABC.canvas"), in: folder)?.id, "ABC")
        XCTAssertNil(file.space(forCanvas: URL(fileURLWithPath: "/tmp/other.canvas"), in: folder))
    }

    func testTheFileRoundTripsAndAMissingOneIsEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "spaces-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(SpaceFile.read(url), SpaceFile())
        var file = SpaceFile()
        file.spaces = [Space(name: "Music", color: "pink"), Space(color: "blue")]
        try file.write(url)
        XCTAssertEqual(SpaceFile.read(url), file)
    }

    func testAnEmptyCanvasParses() throws {
        let object = try JSONSerialization.jsonObject(with: SpaceCanvas.empty) as? [String: Any]
        XCTAssertEqual((object?["nodes"] as? [Any])?.count, 0)
    }
}
