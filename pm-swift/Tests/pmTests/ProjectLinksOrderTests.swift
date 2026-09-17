import XCTest
@testable import PmLib

/// Dragging a project's links into a new order — canvas backlog 14.
final class ProjectLinksOrderTests: XCTestCase {

    private let a = LinkEntry(label: "A", url: "https://a.example")
    private let b = LinkEntry(url: "https://b.example")
    private let c = LinkEntry(label: "C", url: "https://c.example")
    private let group = LinkEntry(label: "Design", children: [LinkEntry(url: "https://figma.com/x")])

    func testALinkMovesToWhereItWasLetGo() {
        XCTAssertEqual([a, b, c].movingLink(from: 0, to: 2), [b, c, a])
        XCTAssertEqual([a, b, c].movingLink(from: 2, to: 0), [c, a, b])
        XCTAssertEqual([a, b, c].movingLink(from: 1, to: 1), [a, b, c], "where it was is no move")
        XCTAssertEqual([a, b, c].movingLink(from: 5, to: 0), [a, b, c])
    }

    /// A group and the blank placeholder keep their places; the links move around them.
    func testGroupsAndTheBlankStayPut() {
        let list = [a, group, b, LinkEntry(), c]
        XCTAssertEqual(list.movableLinkSlots, [0, 2, 4])
        XCTAssertEqual(list.movingLink(from: 0, to: 2), [b, group, c, LinkEntry(), a])
    }

    /// Written back in the new order, and read back the same.
    func testTheFileIsWrittenInTheNewOrder() throws {
        let raw = NotesRawEditTests.messyMarkdown.replacingOccurrences(
            of: "- Label: https://example.com",
            with: "- A: https://a.example\n- https://b.example\n- Design\n    - https://figma.com/x\n- C: https://c.example")
        let notes = try parseNotes(markdown: raw)
        var moved = notes
        moved.links = notes.links.movingLink(from: 2, to: 0)
        let written = try XCTUnwrap(writeNotesPreservingFormat(rawText: raw, incoming: moved, kind: .project))
        XCTAssertEqual(try parseNotes(markdown: written).links.map { $0.url ?? $0.label }, ["https://c.example", "https://a.example", "Design", "https://b.example"].map(Optional.some))
        XCTAssertTrue(written.contains("tags: [project, design]"), "the rest of the file is left alone")
        XCTAssertTrue(written.contains("#project-tag"))
    }
}
