import XCTest
@testable import PmLib

final class NotesRoundTripTests: XCTestCase {
    /// Fixture markdown matching templates/notes.md structure (no leading spaces on ### lines)
    static let fixtureMarkdown = """
# My Project

> [!summary] Summary
> One line summary.

> [!question] Problem
> The problem statement.

> [!info] Goals
> 1.  First goal
> 2.  Second goal
> 3.  Third goal

> [!info] Approach
> How we approach it.

## Links

- Label: https://example.com
- https://bare.com

## Learnings

- Learning one
- Learning two

## Sessions

### Wed, Feb 25, 2025

- [ ] Todo one
- [x] Todo two

### Thu, Mar 6, 2025 Sprint 1

- [x] Done item
"""

    /// Parse extracts expected content; then round-trip preserves it.
    func testRoundTrip() throws {
        let parsed = try parseNotes(markdown: Self.fixtureMarkdown)
        // Assert parse actually extracted the fixture content (not just idempotence of empty)
        XCTAssertEqual(parsed.title, "My Project")
        XCTAssertEqual(parsed.summary.trimmingCharacters(in: .whitespacesAndNewlines), "One line summary.")
        XCTAssertEqual(parsed.problem.trimmingCharacters(in: .whitespacesAndNewlines), "The problem statement.")
        XCTAssertEqual(parsed.goals.prefix(3).map { $0.trimmingCharacters(in: .whitespaces) }, ["First goal", "Second goal", "Third goal"])
        XCTAssertEqual(parsed.sessions.count, 2)
        XCTAssertEqual(parsed.sessions[0].date, "Wed, Feb 25, 2025")
        XCTAssertEqual(parsed.sessions[0].label, "")
        XCTAssertTrue(parsed.sessions[0].body.contains("[ ] Todo one"))
        XCTAssertTrue(parsed.sessions[0].body.contains("[x] Todo two"))
        XCTAssertEqual(parsed.sessions[1].date, "Thu, Mar 6, 2025")
        XCTAssertEqual(parsed.sessions[1].label, "Sprint 1")
        XCTAssertTrue(parsed.sessions[1].body.contains("[x] Done item"))

        let serialized = serializeNotes(parsed)
        let reparsed = try parseNotes(markdown: serialized)
        XCTAssertEqual(parsed, reparsed, "Round-trip parse → serialize → parse should equal original")
    }

    /// Empty template parses to expected shape (sections present, empty content); round-trip preserves it.
    func testEmptyTemplateRoundTrip() throws {
        let template = notesTemplate.replacingOccurrences(of: "{{title}}", with: "Test")
        let parsed = try parseNotes(markdown: template)
        XCTAssertEqual(parsed.title, "Test")
        // Assert empty template produces expected structure (not just title).
        XCTAssertEqual(parsed.goals.count, 3, "Goals section should parse to 3 slots")
        XCTAssertTrue(parsed.links.count >= 1, "Links section should parse")
        XCTAssertTrue(parsed.learnings.count >= 1, "Learnings section should parse")
        XCTAssertEqual(parsed.sessions.count, 0, "Empty template has no sessions")
        let serialized = serializeNotes(parsed)
        let reparsed = try parseNotes(markdown: serialized)
        XCTAssertEqual(parsed, reparsed, "Empty template parse → serialize → parse should equal original")
    }
}
