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

    func testEmptyTemplateRoundTrip() throws {
        let template = notesTemplate.replacingOccurrences(of: "{{title}}", with: "Test")
        let parsed = try parseNotes(markdown: template)
        XCTAssertEqual(parsed.title, "Test")
        let serialized = serializeNotes(parsed)
        let reparsed = try parseNotes(markdown: serialized)
        XCTAssertEqual(parsed, reparsed, "Empty template parse → serialize → parse should equal original")
    }

    /// Reordered sections (Sessions, Links, Learnings) still parse correctly; parser is order-independent.
    func testReorderedSectionsParseCorrectly() throws {
        let markdownReordered = """
# Reordered Project

> [!summary] Summary
> Summary here.

> [!question] Problem
> Problem here.

> [!info] Goals
> 1.  G1
> 2.  G2
> 3.  G3

> [!info] Approach
> Approach here.

## Sessions

### Mon, Jan 1, 2024

- [ ] Only session todo

## Links

- Link One: https://one.com
- https://bare.com

## Learnings

- Learning A
- Learning B
"""
        let parsed = try parseNotes(markdown: markdownReordered)
        XCTAssertEqual(parsed.title, "Reordered Project")
        XCTAssertEqual(parsed.sessions.count, 1)
        XCTAssertEqual(parsed.sessions[0].date, "Mon, Jan 1, 2024")
        XCTAssertTrue(parsed.sessions[0].body.contains("[ ] Only session todo"))
        XCTAssertEqual(parsed.links.count, 2)
        XCTAssertEqual(parsed.links[0].label, "Link One")
        XCTAssertEqual(parsed.links[0].url, "https://one.com")
        XCTAssertEqual(parsed.links[1].url, "https://bare.com")
        XCTAssertEqual(parsed.learnings.filter { !$0.isEmpty }, ["Learning A", "Learning B"])

        // Round-trip reordered doc: serialize then reparse preserves content (output is canonical order).
        let serialized = serializeNotes(parsed)
        let reparsed = try parseNotes(markdown: serialized)
        XCTAssertEqual(parsed.title, reparsed.title)
        XCTAssertEqual(parsed.sessions.count, reparsed.sessions.count)
        XCTAssertEqual(parsed.links.count, reparsed.links.count)
        XCTAssertEqual(parsed.learnings.filter { !$0.isEmpty }, reparsed.learnings.filter { !$0.isEmpty })
    }
}
