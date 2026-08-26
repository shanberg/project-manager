import XCTest
@testable import PmLib

final class ProjectKindTests: XCTestCase {

    // MARK: The section metadata has to agree with the parser

    /// `HeaderSection` carries the callout type and label that serialization writes, and `parseNotes`
    /// has its own regexes for the same four blocks. Those are two statements of one fact, and this is
    /// what stops them drifting: build each section from its own metadata, and assert the parser finds
    /// it where it belongs.
    ///
    /// Without this, renaming a label or changing a callout type produces documents that serialize
    /// happily and come back empty — a silent loss, since the parser skips what it doesn't recognize.
    func testEveryHeaderSectionParsesFromItsOwnMetadata() throws {
        for section in HeaderSection.allCases {
            let body: String
            switch section.shape {
            case .prose: body = "> the content of \(section.label)"
            case .numberedList: body = "> 1.  first\n> 2.  second\n> 3.  third"
            }
            let markdown = """
            # Test

            > [!\(section.calloutType)] \(section.label)
            \(body)

            ## Links

            ## Learnings

            ## Sessions

            """

            let notes = try parseNotes(markdown: markdown)
            switch notes.content(section) {
            case .prose(let text):
                XCTAssertEqual(text, "the content of \(section.label)",
                               "\(section.rawValue) did not round-trip through its own callout metadata")
            case .numbered(let items):
                XCTAssertEqual(Array(items.prefix(3)), ["first", "second", "third"],
                               "\(section.rawValue) did not round-trip through its own callout metadata")
            }
        }
    }

    /// The two `[!info]` sections are told apart by label alone, so a document containing both must
    /// not let one swallow the other.
    func testTheTwoInfoSectionsDoNotCollide() throws {
        let markdown = """
        # Test

        > [!info] Goals
        > 1.  ship it
        > 2.  
        > 3.  

        > [!info] Approach
        > incrementally

        ## Links

        ## Learnings

        ## Sessions

        """
        let notes = try parseNotes(markdown: markdown)
        XCTAssertEqual(notes.goals.first, "ship it")
        XCTAssertEqual(notes.approach, "incrementally")
    }

    // MARK: The kinds

    /// An area's header is a subset of a project's, not a parallel vocabulary. This is the property
    /// that keeps the divergence to one array: no new callout, no new regex, no new field.
    func testAreaSectionsAreASubsetOfProjectSections() {
        let project = ProjectKind.project.headerSections
        let area = ProjectKind.area.headerSections
        XCTAssertTrue(area.allSatisfy(project.contains),
                      "an area section that isn't a project section means a vocabulary was invented")
        XCTAssertEqual(area, [.summary, .goals])
        XCTAssertFalse(area.contains(.problem), "Problem describes a finish line")
        XCTAssertFalse(area.contains(.approach), "Approach describes a finish line")
    }

    /// Sections keep document order, so serializing from the list writes them in the order a reader
    /// expects rather than the order the enum happens to declare.
    func testHeaderSectionsAreInDocumentOrder() {
        XCTAssertEqual(ProjectKind.project.headerSections, [.summary, .problem, .goals, .approach])
    }

    func testOnlyProjectsAreNumbered() {
        XCTAssertTrue(ProjectKind.project.isNumbered)
        XCTAssertFalse(ProjectKind.area.isNumbered)
    }

    // MARK: Emptiness, which the write-side rule turns on

    /// A section holding only whitespace is empty. The omission rule keeps a *non-empty* section that
    /// the kind doesn't include, so "empty" being sloppy here would mint blank callouts in every area.
    func testWhitespaceOnlySectionsAreEmpty() {
        let notes = ProjectNotes(title: "T", summary: "  \n ", problem: "", goals: ["", "  ", ""], approach: "")
        for section in HeaderSection.allCases {
            XCTAssertTrue(notes.isEmpty(section), "\(section.rawValue) should read as empty")
        }
    }

    func testNonEmptySectionsAreNotEmpty() {
        let notes = ProjectNotes(title: "T", summary: "s", problem: "p", goals: ["", "g", ""], approach: "a")
        for section in HeaderSection.allCases {
            XCTAssertFalse(notes.isEmpty(section), "\(section.rawValue) should read as non-empty")
        }
    }
}
