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

    /// Stop Waiting from a Waiting view's row clears the token through the project's store, as one step
    /// ⌘Z takes back — and the Waiting answer follows.
    func testStopWaitingFromAWaitingRowIsTakenBackByUndo() throws {
        _ = try api("project.create") { $0.title = "Launch"; $0.domain = "W" }
        _ = try api("project.create") { $0.title = "Site"; $0.domain = "W" }
        _ = try api("task.add") { $0.project = "W-1"; $0.text = "Ship it waiting: [[W-2 Site]]" }
        let hit = try XCTUnwrap(try waitingBuckets().first?.tasks.first, "the task is waiting")
        let row = CanvasTaskLists.row(hit)
        XCTAssertTrue(CanvasDayAction.offered(forTasks: [row]).contains(.stopWaiting))

        var lastEditedProject: PMStore?
        let actions = CanvasDayActions { [unowned self] in projectKey(forFolder: $0) }
        actions.onActed = { lastEditedProject = $0 }
        defer { actions.releaseAll() }
        let settled = expectation(description: "act settled")
        actions.perform(.stopWaiting, on: [row], inProject: hit.projectFolder) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertTrue(try waitingBuckets().isEmpty, "the wait is cleared on disk")

        let project = try XCTUnwrap(lastEditedProject, "the act became the board's last edit")
        let undone = expectation(description: "undone")
        project.undo()
        project.reload { undone.fulfill() }
        wait(for: [undone], timeout: 5)
        XCTAssertEqual(try waitingBuckets().first?.tasks.map(\.text), ["Ship it"], "⌘Z put the wait back")
    }

    /// Pick Up from a Leftovers row takes the task into its own project's current sitting — started for
    /// it, since the project has none today — and ⌘Z on the board takes the pick back (D6).
    func testPickUpFromLeftoversIsTakenBackByUndo() throws {
        _ = try api("project.create") { $0.title = "Launch"; $0.domain = "W" }
        let projectPath = try resolveProjectPath(nameOrPrefix: "W-1")
        let notesPath = try XCTUnwrap(try resolveNotesPath(projectPath: projectPath))
        let heading = DateFormatter()
        heading.locale = Locale(identifier: "en_US_POSIX")
        heading.dateFormat = "EEE, MMM d, yyyy"
        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
        let text = try String(contentsOfFile: notesPath, encoding: .utf8)
        let marker = try XCTUnwrap(text.range(of: "## Sessions\n"))
        try text.replacingCharacters(in: marker, with: "## Sessions\n\n### \(heading.string(from: threeDaysAgo))\n\n- [ ] Ship it\n")
            .write(toFile: notesPath, atomically: true, encoding: .utf8)

        let groups = CanvasTaskLists.groups(leftovers: try leftoverTasks())
        let item = try XCTUnwrap(groups.first?.items.first, "the task is left over")
        XCTAssertEqual(item.hit.text, "Ship it")
        XCTAssertNil(item.picked)
        XCTAssertTrue(CanvasDayAction.offered(forTasks: [item.row()], picking: true).contains(.pickUp))

        var lastEditedProject: PMStore?
        let actions = CanvasDayActions { [unowned self] in projectKey(forFolder: $0) }
        actions.onActed = { lastEditedProject = $0 }
        defer { actions.releaseAll() }
        let settled = expectation(description: "act settled")
        actions.perform(.pickUp, on: [item.row()], inProject: item.hit.projectFolder) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        let picked = try XCTUnwrap(CanvasTaskLists.groups(leftovers: try leftoverTasks()).first?.items.first,
                                   "a picked-up task is still left over")
        XCTAssertEqual(picked.picked?.into, CanvasTaskLists.todayISO(), "into today's sitting, in its own project")
        XCTAssertTrue(picked.row().pickedUp)
        XCTAssertEqual(CanvasDayAction.offered(forTasks: [picked.row()], picking: true),
                       [.complete, .drop, .focus, .putBack], "picked up, it can be put back")

        let project = try XCTUnwrap(lastEditedProject, "the act became the board's last edit")
        let undone = expectation(description: "undone")
        project.undo()
        project.reload { undone.fulfill() }
        wait(for: [undone], timeout: 5)
        XCTAssertNil(try leftoverTasks().projects.first?.sittings.first?.tasks.first?.picked, "⌘Z took the pick back")
    }

    /// A search hit in a day's second sitting names that sitting, so a tick lands on its line — not on the
    /// first sitting's line of the same number, which here says the same thing.
    func testATickOnASearchHitLandsInItsOwnSitting() throws {
        _ = try api("project.create") { $0.title = "Launch"; $0.domain = "W" }
        _ = try api("task.add") { $0.project = "W-1"; $0.text = "Call Dana" }
        _ = try api("session.start") { $0.project = "W-1"; $0.new = true }
        _ = try api("task.add") { $0.project = "W-1"; $0.text = "Call Dana" }

        let hits = try searchableTasks().filter { $0.text == "Call Dana" }
        XCTAssertEqual(hits.compactMap(\.sessionOrdinal).sorted(), [0, 1], "one in each sitting")
        let second = try XCTUnwrap(hits.first { $0.sessionOrdinal == 1 })

        let actions = CanvasDayActions { [unowned self] in projectKey(forFolder: $0) }
        defer { actions.releaseAll() }
        let settled = expectation(description: "act settled")
        actions.perform(.complete, on: [CanvasTaskLists.row(second)], inProject: second.projectFolder) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        let open = try searchableTasks().filter { $0.text == "Call Dana" }
        XCTAssertEqual(open.map(\.sessionOrdinal), [0], "the second sitting's was ticked, the first's is still open")
    }

    /// A selection is one sitting, so one project: two ticks are one step, and one ⌘Z takes both back.
    func testASelectionIsOneStepOnItsProject() throws {
        _ = try api("project.create") { $0.title = "Day Under Test"; $0.domain = "W" }
        _ = try api("task.add") { $0.project = "W-1"; $0.text = "Email Dana" }
        _ = try api("task.add") { $0.project = "W-1"; $0.text = "Book the venue" }
        let (sitting, rows) = try todayRows()
        XCTAssertEqual(rows.count, 2)

        var lastEditedProject: PMStore?
        let actions = CanvasDayActions { [unowned self] in projectKey(forFolder: $0) }
        actions.onActed = { lastEditedProject = $0 }
        defer { actions.releaseAll() }
        let settled = expectation(description: "act settled")
        actions.perform(.complete, on: rows, inProject: sitting.projectFolder) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertEqual(try todayRows().1.map(\.state), [.done, .done])

        let project = try XCTUnwrap(lastEditedProject)
        XCTAssertEqual(project.undoStack.count, 1, "One gesture, one step")
        let undone = expectation(description: "undone")
        project.undo()
        project.reload { undone.fulfill() }
        wait(for: [undone], timeout: 5)
        XCTAssertEqual(try todayRows().1.map(\.state), [.open, .open])
    }

    /// A sitting dragged off a view: the card it carries, read back by the board's own drop reader, is a
    /// project card on that project's notes, drawing that one sitting (docs/views.md D7).
    func testASittingDraggedOffIsACardOfThatSitting() throws {
        _ = try api("project.create") { $0.title = "Day Under Test"; $0.domain = "W" }
        _ = try api("task.add") { $0.project = "W-1"; $0.text = "Email Dana" }
        let (sitting, _) = try todayRows()
        let resolver = CanvasFileResolver(canvas: vault.appendingPathComponent("PARA/Board.canvas"),
                                          vaultRoot: vault.appendingPathComponent("PARA"))
        let document = try XCTUnwrap(CanvasSittingPin.card(for: sitting, resolver: resolver))

        let pasteboard = NSPasteboard(name: .init("pm-day-drag-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(Data(document.serialized().utf8), forType: CanvasClipping.pasteboardType)
        pasteboard.setString(sitting.projectName, forType: .string)
        guard case .cards(let dropped)? = CanvasDrop.read(pasteboard, cardsType: CanvasClipping.pasteboardType)
        else { return XCTFail("The board reads it as a card, not as text") }

        let node = try XCTUnwrap(dropped.nodes.first)
        XCTAssertEqual(dropped.nodes.count, 1)
        XCTAssertEqual(CanvasCardShows.of(node), .sitting)
        guard case .file(let path, nil) = node.content else { return XCTFail("A file card") }
        XCTAssertFalse(path.hasPrefix("/"), "Stored from the vault root, as Obsidian stores it")
        let url = try XCTUnwrap(resolver.resolve(path).url)
        let notes = try parseNotes(markdown: String(contentsOf: url, encoding: .utf8))
        let pin = try XCTUnwrap(CanvasSittingPin.of(node))
        let index = try XCTUnwrap(CanvasSittingPin.index(of: pin, in: notes))
        XCTAssertEqual(sessionISODate(heading: notes.sessions[index].date), sitting.session,
                       "The card draws the sitting that was dragged")
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

/// ⌘Z while retyping a task is the typing's, not the board's or the project's.
@MainActor
final class CanvasTypingUndoTests: XCTestCase {
    func testAFieldBeingRetypedIsTheEditorWithAHistoryOfItsOwn() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.backgroundColor = .windowBackgroundColor
        let card = NSView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(card)
        let field = TokenClickField(string: "Email Dana")
        field.frame = NSRect(x: 10, y: 10, width: 200, height: 22)
        card.addSubview(field)

        XCTAssertNil(CanvasUndoRoute.typingUndo(in: card), "Nothing is being typed yet")
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText(" today", replacementRange: NSRange(location: 10, length: 0))
        editor.breakUndoCoalescing()

        let typing = try XCTUnwrap(CanvasUndoRoute.typingUndo(in: card))
        XCTAssertTrue(typing === field.typingUndo)
        XCTAssertFalse(typing === window.undoManager, "Not the window's, which on a board is the canvas")
        XCTAssertTrue(typing.canUndo)
        XCTAssertEqual(CanvasUndoRoute.route(editorOpen: true, projectCanAct: true), .editor)
        typing.undo()
        XCTAssertEqual(editor.string, "Email Dana", "⌘Z took back the typing")

        let elsewhere = NSView()
        window.contentView!.addSubview(elsewhere)
        XCTAssertNil(CanvasUndoRoute.typingUndo(in: elsewhere), "Only the card with the caret in it")
    }
}
