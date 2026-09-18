import XCTest

/// Where ⌘Z goes on a board. See `CanvasUndoRoute`.
final class CanvasUndoRouteTests: XCTestCase {

    /// The case that lost notes: a session note open on a project card whose history has a step on it
    /// — as it always does once the note has saved once. ⌘Z is the note's.
    func testAnOpenEditorWinsOverAProjectWithHistory() {
        XCTAssertEqual(CanvasUndoRoute.route(editorOpen: true, projectCanAct: true), .editor)
    }

    /// And stays the note's with nothing left on its own stack, rather than reaching past it.
    func testAnOpenEditorWinsEvenWithNothingToUndo() {
        XCTAssertEqual(CanvasUndoRoute.route(editorOpen: true, projectCanAct: false), .editor)
    }

    func testWithNoEditorTheProjectEditedLastComesBeforeTheBoard() {
        XCTAssertEqual(CanvasUndoRoute.route(editorOpen: false, projectCanAct: true), .project)
        XCTAssertEqual(CanvasUndoRoute.route(editorOpen: false, projectCanAct: false), .board)
    }
}

import PmLib

/// A tick on a Day row, taken back by ⌘Z on the board (docs/views.md D6, build step 4).
///
/// The row is read the way the card reads it — `session.list`, then `CanvasDayRows` — and acted on the
/// way the card acts, through `CanvasDayActions` and the registry's store. What the pane does with ⌘Z is
/// `CanvasUndoRoute` over the board's `lastEditedProject`, which is the store the act hands back.
@MainActor
final class CanvasDayRowUndoTests: XCTestCase {

    private var vault: URL!
    private var previousConfigHome: String?

    override func setUp() {
        super.setUp()
        vault = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm-day-undo-tests-\(UUID().uuidString)")
        let config = vault.appendingPathComponent("config")
        let para = vault.appendingPathComponent("PARA")
        for dir in [config, para.appendingPathComponent("Projects"), para.appendingPathComponent("Archive"),
                    para.appendingPathComponent("Areas")] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let settings = """
        {
          "activePath": "\(para.appendingPathComponent("Projects").path)",
          "archivePath": "\(para.appendingPathComponent("Archive").path)",
          "areasPath": "\(para.appendingPathComponent("Areas").path)",
          "paraPath": "\(para.path)",
          "domains": { "W": "Work" },
          "subfolders": ["docs"]
        }
        """
        try? settings.write(to: config.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        previousConfigHome = ProcessInfo.processInfo.environment["PM_CONFIG_HOME"]
        setenv("PM_CONFIG_HOME", config.path, 1)
    }

    override func tearDown() {
        if let previousConfigHome { setenv("PM_CONFIG_HOME", previousConfigHome, 1) } else { unsetenv("PM_CONFIG_HOME") }
        try? FileManager.default.removeItem(at: vault)
        vault = nil
        super.tearDown()
    }

    private func api(_ action: String, _ build: (inout ApiInput) -> Void = { _ in }) throws -> ApiResult {
        var input = ApiInput()
        build(&input)
        return try performApi(action, input, options: ApiOptions(source: "test"))
    }

    /// `<containing folder>:<folder>`, from the project list — the key the registry keeps stores under.
    private func projectKey(forFolder folder: String) -> String? {
        guard let projects = (try? api("project.list"))?.data?.arrayValue else { return nil }
        for project in projects {
            guard let object = project.objectValue, object["folder"]?.stringValue == folder,
                  let path = object["path"]?.stringValue else { continue }
            return "\((path as NSString).deletingLastPathComponent):\(folder)"
        }
        return nil
    }

    private func todayRows() throws -> (SittingEntry, [CanvasDayRow]) {
        let list = try sessionList(in: try DoneRange.resolve(period: "today", since: nil, until: nil), projects: nil)
        let sitting = try XCTUnwrap(list.sittings.first, "the project's sitting today")
        return (sitting, CanvasDayRows.rows(sitting))
    }

    private func perform(_ act: CanvasDayAction, _ row: CanvasDayRow, in sitting: SittingEntry,
                         with actions: CanvasDayActions) {
        let settled = expectation(description: "act settled")
        actions.perform(act, on: row, inProject: sitting.projectFolder) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
    }

    func testATickOnADayRowIsTakenBackByUndoOnTheBoard() throws {
        _ = try api("project.create") { $0.title = "Day Under Test"; $0.domain = "W" }
        _ = try api("task.add") { $0.project = "W-1"; $0.text = "Email Dana" }
        let (sitting, rows) = try todayRows()
        let row = try XCTUnwrap(rows.first { $0.text == "Email Dana" })
        XCTAssertEqual(row.state, .open)
        XCTAssertEqual(CanvasDayAction.offered(for: row, in: sitting).first, .complete)

        // Stands in for the board: what `CanvasViewNodeView` does with an act that landed.
        var lastEditedProject: PMStore?
        let actions = CanvasDayActions { [unowned self] in projectKey(forFolder: $0) }
        actions.onActed = { lastEditedProject = $0 }
        defer { actions.releaseAll() }

        XCTAssertTrue(actions.heldProjects.isEmpty, "Drawing the view holds no project open")
        perform(.complete, row, in: sitting, with: actions)
        XCTAssertEqual(actions.heldProjects.count, 1, "Acting took the one project it acted on")
        XCTAssertEqual(try todayRows().1.first { $0.text == "Email Dana" }?.state, .done, "The tick is on disk")

        let project = try XCTUnwrap(lastEditedProject, "The act became the board's last edit")
        XCTAssertEqual(CanvasUndoRoute.route(editorOpen: false, projectCanAct: project.canUndo), .project,
                       "⌘Z goes to the project, not the board")

        // What the pane's `undo(_:)` does on the project route.
        let undone = expectation(description: "undone")
        project.undo()
        project.reload { undone.fulfill() }
        wait(for: [undone], timeout: 5)
        XCTAssertEqual(try todayRows().1.first { $0.text == "Email Dana" }?.state, .open, "⌘Z brought the task back")
    }

    /// A row whose line changed under the view is refused, not landed on whatever is there now.
    func testAnActOnALineThatChangedIsRefused() throws {
        _ = try api("project.create") { $0.title = "Day Under Test"; $0.domain = "W" }
        _ = try api("task.add") { $0.project = "W-1"; $0.text = "Email Dana" }
        let (sitting, rows) = try todayRows()
        let row = try XCTUnwrap(rows.first)
        _ = try api("task.setText") { $0.project = "W-1"; $0.task = row.ref; $0.text = "Call Dana" }

        var acted = false
        let actions = CanvasDayActions { [unowned self] in projectKey(forFolder: $0) }
        actions.onActed = { _ in acted = true }
        defer { actions.releaseAll() }
        perform(.complete, row, in: sitting, with: actions)
        XCTAssertFalse(acted)
        XCTAssertEqual(try todayRows().1.first?.state, .open)
    }
}
