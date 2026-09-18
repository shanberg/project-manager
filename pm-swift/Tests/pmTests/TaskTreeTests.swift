import XCTest
@testable import PmLib

/// What a pick takes: the tree a task belongs to, named by its root. See docs/sessions.md D3.
final class TaskTreeTests: XCTestCase {

    private let doc = """
    # Offsite

    ## Sessions

    ### Thu, Sep 17, 2026

    - [ ] Draft the agenda

    ### Wed, Sep 2, 2026

    - [ ] Plan the offsite
      - [ ] Find a room
        - [ ] Ask about the projector
      - [ ] Book catering
    - [ ] Email Dana

    """

    private func todos(_ markdown: String) throws -> [Todo] {
        try parseTodos(notes: normalizeFocusMarker(notes: try parseNotes(markdown: markdown)))
    }

    private func named(_ text: String, in todos: [Todo]) throws -> Todo {
        try XCTUnwrap(todos.first { $0.text == text })
    }

    func testASubtaskBelongsToTheTopLevelTaskAboveIt() throws {
        let todos = try todos(doc)
        for text in ["Plan the offsite", "Find a room", "Ask about the projector", "Book catering"] {
            XCTAssertEqual(TaskTree.root(of: try named(text, in: todos), in: todos).text, "Plan the offsite", text)
        }
        XCTAssertEqual(TaskTree.root(of: try named("Email Dana", in: todos), in: todos).text, "Email Dana")
    }

    func testATreeIsItsRootAndEverythingUnderIt() throws {
        let todos = try todos(doc)
        let tree = TaskTree.members(of: try named("Plan the offsite", in: todos), in: todos)
        XCTAssertEqual(tree.map(\.text), ["Plan the offsite", "Find a room", "Ask about the projector", "Book catering"])
    }

    /// Trees never reach across a heading: the last task of one sitting isn't the parent of the first
    /// task of the next.
    func testATreeStopsAtItsSitting() throws {
        let todos = try todos(doc)
        XCTAssertEqual(TaskTree.members(of: try named("Draft the agenda", in: todos), in: todos).map(\.text),
                       ["Draft the agenda"])
    }

    /// A sitting that opens on an indented line (a hand edit) has no top-level line above it. The task
    /// is its own root rather than borrowing one.
    func testAnIndentedFirstLineIsItsOwnRoot() throws {
        let todos = try todos("""
        # Offsite

        ## Sessions

        ### Wed, Sep 2, 2026

            - [ ] Find a room
        - [ ] Email Dana

        """)
        let room = try named("Find a room", in: todos)
        XCTAssertEqual(TaskTree.root(of: room, in: todos).text, "Find a room")
    }

    func testTheTreesOfASelectionAreEachCountedOnce() throws {
        let todos = try todos(doc)
        let selection = try ["Find a room", "Book catering", "Email Dana", "Plan the offsite"].map { try named($0, in: todos) }
        XCTAssertEqual(TaskTree.roots(of: selection, in: todos).map(\.text), ["Plan the offsite", "Email Dana"])
    }
}
