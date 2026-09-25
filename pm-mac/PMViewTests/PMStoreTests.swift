import PmLib
import XCTest

/// The store that writes your notes, against a vault made for the test and thrown away after it.
///
/// **Why this had no tests until now.** Not difficulty — `PMStore` reaches `loadConfig()`,
/// `resolveNotesHandle` and `PMContract`, all of which resolve through PmLib's config dir, and
/// `getConfigDir()` reads `PM_CONFIG_HOME` from the environment on *every* call rather than caching
/// it. The seam was there the whole time. What blocked it was that `PMContract` carried the affordance
/// tier in the same file — `WindowManager`, `FocusPanelController`, `SettingsWindowController`,
/// `ObsidianLink` — so the adapter could not be compiled without the whole app around it. Splitting
/// that tier into `PMAffordances.swift`, which is what the contract's own tiers already said should
/// happen, is the entire reason this file can exist.
///
/// Each test gets its own vault directory, so nothing here can see another test's writes or anybody's
/// real notes.
@MainActor
final class PMStoreTests: XCTestCase {

    private var vault: URL!
    private var previousConfigHome: String?

    override func setUp() {
        super.setUp()
        vault = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm-store-tests-\(UUID().uuidString)")
        let config = vault.appendingPathComponent("config")
        let projects = vault.appendingPathComponent("PARA/Projects")
        let archive = vault.appendingPathComponent("PARA/Archive")
        let areas = vault.appendingPathComponent("PARA/Areas")
        for dir in [config, projects, archive, areas] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let settings = """
        {
          "activePath": "\(projects.path)",
          "archivePath": "\(archive.path)",
          "areasPath": "\(areas.path)",
          "paraPath": "\(vault.appendingPathComponent("PARA").path)",
          "domains": { "W": "Work" },
          "subfolders": ["docs"]
        }
        """
        try? settings.write(to: config.appendingPathComponent("config.json"),
                            atomically: true, encoding: .utf8)

        // The one piece of process-global state in play. Restored in tearDown so a later test that
        // wants the real config dir still gets it — and noted here because it is also why these tests
        // cannot run in parallel with anything that reads config.
        previousConfigHome = ProcessInfo.processInfo.environment["PM_CONFIG_HOME"]
        setenv("PM_CONFIG_HOME", config.path, 1)
    }

    override func tearDown() {
        if let previousConfigHome { setenv("PM_CONFIG_HOME", previousConfigHome, 1) }
        else { unsetenv("PM_CONFIG_HOME") }
        try? FileManager.default.removeItem(at: vault)
        vault = nil
        super.tearDown()
    }

    // MARK: Building a project to act on

    /// Create a project with `text` as its tasks, and return a store bound to it, loaded.
    private func store(withTasks text: String) throws -> PMStore {
        try create(titled: "Store Under Test")
        for line in text.split(separator: "\n") {
            var input = ApiInput()
            input.project = "W-1"
            input.text = String(line)
            _ = try performApi("task.add", input, options: ApiOptions(source: "test"))
        }
        let key = try XCTUnwrap(projectKey(for: "W-1"))
        let store = PMStore(boundKey: key)
        try loadAndWait(store)
        return store
    }

    /// Make a project. `ApiInput` is one struct of twenty-nine optional fields for forty-three
    /// actions, so this is assignment rather than an initialiser — see item 3 of
    /// docs/structural-work.md, which is about exactly this ergonomics.
    private func create(titled title: String) throws {
        var input = ApiInput()
        input.title = title
        input.domain = "W"
        _ = try performApi("project.create", input, options: ApiOptions(source: "test"))
    }

    /// A project key is `<containing folder>:<folder name>` — the spelling `focused.json` uses.
    private func projectKey(for prefix: String) throws -> String? {
        let listing = try performApi("project.list", ApiInput(), options: ApiOptions(source: "test"))
        guard let projects = listing.data?.arrayValue else { return nil }
        for project in projects {
            guard let object = project.objectValue,
                  let folder = object["folder"]?.stringValue, folder.hasPrefix(prefix),
                  let path = object["path"]?.stringValue else { continue }
            return "\((path as NSString).deletingLastPathComponent):\(folder)"
        }
        return nil
    }

    /// `reload` is asynchronous — it reads off the main actor and publishes back. Wait for its
    /// completion rather than guessing at a sleep.
    private func loadAndWait(_ store: PMStore, file: StaticString = #filePath, line: UInt = #line) throws {
        let loaded = expectation(description: "store loaded")
        store.reload { loaded.fulfill() }
        wait(for: [loaded], timeout: 5)
    }

    /// Run a mutation that reports through a completion, and wait for the reload that follows it.
    private func mutateAndWait(_ store: PMStore, _ work: (@escaping @MainActor () -> Void) -> Void) {
        let settled = expectation(description: "mutation settled")
        work { settled.fulfill() }
        wait(for: [settled], timeout: 5)
    }

    // MARK: The vault itself

    /// If this fails, nothing else in the file means anything — it would be reading somebody's real
    /// notes instead of the fixture.
    func testTheStoreIsLookingAtTheTestVaultAndNotTheRealOne() throws {
        let store = try store(withTasks: "First task")
        let path = try XCTUnwrap(store.notesPath)
        XCTAssertTrue(path.hasPrefix(vault.path),
                      "the store resolved \(path), which is outside the test vault")
    }

    // MARK: Loading

    func testLoadingReadsTheTasksThatAreOnDisk() throws {
        let store = try store(withTasks: "First task\nSecond task")
        XCTAssertTrue(store.hasLoaded)
        XCTAssertEqual(store.todos.map(\.text), ["First task", "Second task"])
        XCTAssertNil(store.errorMessage)
    }

    func testProgressCountsWhatIsDone() throws {
        let store = try store(withTasks: "First task\nSecond task")
        XCTAssertEqual(store.progress.done, 0)
        XCTAssertEqual(store.progress.total, 2)

        let first = try XCTUnwrap(store.todos.first)
        mutateAndWait(store) { done in store.complete(first, advanceFocus: false, then: done) }

        XCTAssertEqual(store.progress.done, 1)
        XCTAssertEqual(store.progress.total, 2)
    }

    // MARK: Writing

    func testCompletingATaskWritesItToDisk() throws {
        let store = try store(withTasks: "First task\nSecond task")
        let first = try XCTUnwrap(store.todos.first)
        mutateAndWait(store) { done in store.complete(first, advanceFocus: false, then: done) }

        XCTAssertTrue(try XCTUnwrap(store.todos.first).checked)
        let raw = try String(contentsOfFile: XCTUnwrap(store.notesPath), encoding: .utf8)
        XCTAssertTrue(raw.contains("[x] First task"), "the tick did not reach the file:\n\(raw)")
    }

    // MARK: Dropping

    /// Dropped is closed but not done: struck from what's left, and out of the total rather than
    /// counted in the done.
    func testDroppingATaskWritesItAndTakesItOutOfTheTotal() throws {
        let store = try store(withTasks: "First task\nSecond task")
        let first = try XCTUnwrap(store.todos.first)
        mutateAndWait(store) { done in store.drop([first], then: done) }

        XCTAssertEqual(store.todos.first?.state, .dropped)
        let raw = try String(contentsOfFile: XCTUnwrap(store.notesPath), encoding: .utf8)
        XCTAssertTrue(raw.contains("[-] First task"), "the drop did not reach the file:\n\(raw)")
        XCTAssertEqual(store.progress.done, 0)
        XCTAssertEqual(store.progress.total, 1)
    }

    /// A selection swept over finished work doesn't turn it into dropped work, and the whole drop is
    /// one ⌘Z however many tasks it took.
    func testDroppingASelectionLeavesDoneWorkAndIsOneUndoStep() throws {
        let store = try store(withTasks: "First task\nSecond task\nThird task")
        let first = try XCTUnwrap(store.todos.first)
        mutateAndWait(store) { done in store.complete(first, advanceFocus: false, then: done) }
        let beforeDrop = try String(contentsOfFile: XCTUnwrap(store.notesPath), encoding: .utf8)

        mutateAndWait(store) { done in store.drop(store.todos, then: done) }
        XCTAssertEqual(store.todos.map(\.state), [.done, .dropped, .dropped])

        store.undo()
        try waitForFile(store) { $0 == beforeDrop }
    }

    // MARK: Undo

    /// **The property undo exists for.** The store banks the pre-edit document, so undoing restores
    /// the bytes rather than trying to invert the operation.
    func testUndoPutsTheDocumentBackAndRedoReappliesIt() throws {
        let store = try store(withTasks: "First task")
        let before = try String(contentsOfFile: XCTUnwrap(store.notesPath), encoding: .utf8)

        let first = try XCTUnwrap(store.todos.first)
        mutateAndWait(store) { done in store.complete(first, advanceFocus: false, then: done) }
        XCTAssertTrue(store.canUndo, "a real edit should have banked an undo step")

        store.undo()
        try waitForFile(store) { $0 == before }
        XCTAssertEqual(try String(contentsOfFile: XCTUnwrap(store.notesPath), encoding: .utf8), before)

        store.redo()
        try waitForFile(store) { $0.contains("[x] First task") }
    }

    /// **A no-op write must not cost a ⌘Z step.** `mutate` banks the pre-edit document only when the
    /// bytes actually moved, and focus is a navigation rather than an edit — so neither leaves
    /// anything on the stack for undo to find.
    func testMovingTheFocusDoesNotBankAnUndoStep() throws {
        let store = try store(withTasks: "First task\nSecond task")
        XCTAssertFalse(store.canUndo)

        let second = try XCTUnwrap(store.todos.last)
        mutateAndWait(store) { done in store.focus(second, then: done) }

        XCTAssertFalse(store.canUndo, "moving the focus is not an edit and should not be undoable")
    }

    /// Undo does not survive a change of project: the two documents are unrelated, and offering to
    /// undo one into the other would be offering to corrupt it.
    func testSwitchingProjectClearsTheUndoStack() throws {
        let store = try store(withTasks: "First task")
        let first = try XCTUnwrap(store.todos.first)
        mutateAndWait(store) { done in store.complete(first, advanceFocus: false, then: done) }
        XCTAssertTrue(store.canUndo)

        try create(titled: "Somewhere Else")
        let other = try XCTUnwrap(projectKey(for: "W-2"))
        store.bind(to: other)
        try loadAndWait(store)

        XCTAssertFalse(store.canUndo, "the other project's undo stack is not this one's")
    }

    // MARK: Writing against a document that moved

    /// **The race the contract's digests exist for.** The store holds the tasks from its last read,
    /// and the notes file is markdown you also edit in Obsidian. A click acts on what was on screen —
    /// so a write carrying a digest for a line that has since changed is refused rather than applied
    /// to whatever moved into that position. See docs/task-identity.md.
    func testAWriteAgainstATaskThatChangedOnDiskIsRefusedRatherThanMisapplied() throws {
        let store = try store(withTasks: "First task\nSecond task")
        let stale = try XCTUnwrap(store.todos.first)

        // Rewrite the file behind the store's back, so the line the store is holding is not the line
        // that is there any more — and put different text in its place.
        let path = try XCTUnwrap(store.notesPath)
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        try raw.replacingOccurrences(of: "First task", with: "Something else entirely")
            .write(toFile: path, atomically: true, encoding: .utf8)

        let failuresBefore = store.writeFailure?.token
        mutateAndWait(store) { done in store.complete(stale, advanceFocus: false, then: done) }

        let after = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(after.contains("[x] Something else entirely"),
                       "the write landed on the line that replaced the one it was aimed at:\n\(after)")
        XCTAssertNotEqual(store.writeFailure?.token, failuresBefore,
                          "the refusal should have been reported, not swallowed")
    }

    /// Two refusals in a row read as two. The token advances every time, so a banner watching only the
    /// text would sit there looking stale.
    func testEachRefusalIsReportedSeparately() throws {
        let store = try store(withTasks: "First task")
        let stale = try XCTUnwrap(store.todos.first)
        let path = try XCTUnwrap(store.notesPath)
        try String(contentsOfFile: path, encoding: .utf8)
            .replacingOccurrences(of: "First task", with: "Replaced")
            .write(toFile: path, atomically: true, encoding: .utf8)

        mutateAndWait(store) { done in store.complete(stale, advanceFocus: false, then: done) }
        let first = store.writeFailure?.token
        XCTAssertNotNil(first)

        mutateAndWait(store) { done in store.complete(stale, advanceFocus: false, then: done) }
        XCTAssertNotEqual(store.writeFailure?.token, first, "the second refusal reads as its own")
    }

    // MARK: Every write path, against the debug-build completeness check

    /// **Drives each mutation the store offers, in a build where `PMContract.perform` asserts.**
    ///
    /// `ApiInput` is one struct of twenty-nine optional fields, so "did this call remember to set
    /// `clearDue` when `due` is nil" is not a question the compiler can answer — the check added with
    /// `PMAction` answers it at the call site instead, but only for call sites something actually
    /// runs. This runs them. A missing or wrongly-paired field traps here rather than in front of a
    /// person, and the same test fails loudly if a write stops working for any other reason.
    ///
    /// The exclusive pairs are exercised **both ways** — `setDue` with a date and with nil, ditto
    /// `setWaiting` — because setting one of the pair and forgetting the other is the whole failure
    /// mode, and only one direction would catch half of it.
    func testEveryMutationTheStoreOffersRunsWithACompleteInput() throws {
        let store = try store(withTasks: "First task\nSecond task\nThird task")

        func first() throws -> Todo { try XCTUnwrap(store.todos.first) }

        mutateAndWait(store) { done in store.setDue(try! first(), due: "2026-12-25", then: done) }
        mutateAndWait(store) { done in store.setDue(try! first(), due: nil, then: done) }
        mutateAndWait(store) { done in store.setWaiting(try! first(), waiting: "W-2", then: done) }
        mutateAndWait(store) { done in store.setWaiting(try! first(), waiting: nil, then: done) }
        mutateAndWait(store) { done in store.focus(try! first(), then: done) }
        mutateAndWait(store) { done in store.complete(try! first(), advanceFocus: false, then: done) }
        mutateAndWait(store) { done in store.undoLast(then: done) }

        // The ones with no completion to wait on: fire, then wait for the reload each one triggers.
        store.editText(try first(), text: "Renamed task")
        try waitForFile(store) { $0.contains("Renamed task") }

        store.wrap(try first(), parentText: "A parent")
        try waitForFile(store) { $0.contains("A parent") }

        store.unwrap(try XCTUnwrap(store.todos.first { $0.text == "A parent" }))
        try waitForFile(store) { !$0.contains("A parent") }

        store.toggle(try first())
        try waitForFile(store) { $0.contains("[x]") }

        store.undo(try first())
        try waitForFile(store) { !$0.contains("[x]") }

        // Before `toggleAll` below closes everything: a drop only touches open tasks.
        store.drop([try first()])
        try waitForFile(store) { $0.contains("[-]") }

        store.toggleAll(store.todos)
        try waitForFile(store) { $0.components(separatedBy: "[x]").count > 2 }

        store.setDueAll(store.todos, due: "2026-12-26")
        try waitForFile(store) { $0.contains("2026-12-26") }

        store.setDueAll(store.todos, due: nil)
        try waitForFile(store) { !$0.contains("2026-12-26") }

        XCTAssertNil(store.errorMessage, "a write reported an error: \(store.errorMessage ?? "")")
    }

    /// Sessions, the same way.
    func testTheSessionWritesRunWithACompleteInput() throws {
        let store = try store(withTasks: "First task")

        mutateAndWait(store) { done in store.diveIn(then: done) }

        let session = try XCTUnwrap(store.notes?.sessions.indices.last)
        let ref = SessionRef(index: session)
        mutateAndWait(store) { done in store.renameSession(ref, label: "A label", then: done) }
        try waitForFile(store) { $0.contains("A label") }

        store.addTaskToSession(ref, text: "Added to the session")
        try waitForFile(store) { $0.contains("Added to the session") }

        XCTAssertNil(store.errorMessage, "a session write reported an error: \(store.errorMessage ?? "")")
    }

    // MARK: Helpers

    /// Undo and redo write and then reload, with no completion to hang a wait on. Poll until the file
    /// shows the change **and the store has re-read it**.
    ///
    /// The second half is what this helper first lacked, and it made the test using it flaky. A file
    /// shows a write before the reload that follows it lands, so returning on the bytes alone let the
    /// next step act on `store.todos` from before the write — an out-of-date digest the store rightly
    /// refuses, and a five-second timeout further down. `lastEditedAt` is the file's modification date
    /// as of the store's last read, and APFS keeps that to the nanosecond, so it matching the file's
    /// date now is an exact "the store has seen this".
    private func waitForFile(_ store: PMStore, until matches: @escaping (String) -> Bool,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let path = try XCTUnwrap(store.notesPath)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let raw = try? String(contentsOfFile: path, encoding: .utf8), matches(raw),
               let onDisk = notesLastEdited(path: path), store.lastEditedAt == onDisk { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("the file never reached the expected state, or the store never re-read it",
                file: file, line: line)
    }
}

// MARK: - Picking up, and undoing it (docs/sessions.md D3, D4)

extension PMStoreTests {

    /// A project with one task in today's sitting and two left open in one from two weeks ago.
    private func storeWithAnOldSitting() throws -> PMStore {
        let store = try store(withTasks: "Review the contract")
        let path = try XCTUnwrap(store.notesPath)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        try (text + "\n### Wed, Sep 2, 2026\n\nCalled about the venue.\n\n- [ ] Email Dana\n- [ ] Book the venue\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        try loadAndWait(store)
        return store
    }

    private func task(_ text: String, in store: PMStore) throws -> Todo {
        try XCTUnwrap(store.todos.first { $0.text == text }, "no task \(text)")
    }

    private func events(_ store: PMStore) throws -> [PickEvent.Kind] {
        PickLog.events(projectPath: try XCTUnwrap(store.projectPath)).map(\.event)
    }

    /// Wait for a condition on the store that a reload will make true.
    private func waitFor(_ store: PMStore, file: StaticString = #filePath, line: UInt = #line,
                         _ condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("the store never got there", file: file, line: line)
    }

    /// The whole gesture is one step: ⌘Z puts the focus back and releases the pick, ⇧⌘Z does both again.
    func testAFocusThatPicksUpIsOneStepThatUndoTakesBackWhole() throws {
        let store = try storeWithAnOldSitting()
        let focusedBefore = store.todos.first(where: \.isFocused)?.text
        mutateAndWait(store) { done in store.focus(try! self.task("Email Dana", in: store), then: done) }
        XCTAssertEqual(store.todos.first(where: \.isFocused)?.text, "Email Dana")
        XCTAssertNotNil(try task("Email Dana", in: store).picked)
        XCTAssertEqual(store.undoStack.count, 1)
        XCTAssertEqual(store.undoMenuTitle, "Undo Pick Up")

        store.undo()
        waitFor(store) { store.todos.first { $0.text == "Email Dana" }?.picked == nil }
        XCTAssertEqual(store.todos.first(where: \.isFocused)?.text, focusedBefore)
        XCTAssertEqual(try events(store), [.picked, .released])
        XCTAssertEqual(store.redoMenuTitle, "Redo Pick Up")

        store.redo()
        waitFor(store) { store.todos.first { $0.text == "Email Dana" }?.picked != nil }
        XCTAssertEqual(store.todos.first(where: \.isFocused)?.text, "Email Dana")
        XCTAssertEqual(try events(store), [.picked, .released, .picked], "A new pick, not the old one revived")
    }

    /// A focus that picked nothing up is navigation, as it always was.
    func testAFocusThatPicksNothingUpCostsNoStep() throws {
        let store = try storeWithAnOldSitting()
        mutateAndWait(store) { done in store.focus(try! self.task("Email Dana", in: store), then: done) }
        mutateAndWait(store) { done in store.focus(try! self.task("Review the contract", in: store), then: done) }
        mutateAndWait(store) { done in store.focus(try! self.task("Email Dana", in: store), then: done) }
        XCTAssertEqual(store.undoStack.count, 1, "Only the first focus picked anything up")
    }

    func testPickUpAndPutBackAreEachOneStep() throws {
        let store = try storeWithAnOldSitting()
        let before = try String(contentsOfFile: XCTUnwrap(store.notesPath), encoding: .utf8)
        let old = [try task("Email Dana", in: store), try task("Book the venue", in: store)]
        XCTAssertTrue(old.allSatisfy(store.canPickUp))
        XCTAssertFalse(store.canPickUp(try task("Review the contract", in: store)))

        mutateAndWait(store) { done in store.pickUp(old, then: done) }
        XCTAssertEqual(try String(contentsOfFile: XCTUnwrap(store.notesPath), encoding: .utf8), before,
                       "Picking up leaves the notes alone")
        XCTAssertEqual(store.picks.count, 2)
        XCTAssertFalse(store.canPickUp(try task("Email Dana", in: store)))

        mutateAndWait(store) { done in store.putBack([try! self.task("Email Dana", in: store)], then: done) }
        XCTAssertEqual(store.picks.count, 1)
        XCTAssertEqual(store.undoStack.count, 2)
        XCTAssertEqual(store.undoMenuTitle, "Undo Put Back")

        store.undo()
        waitFor(store) { store.picks.count == 2 }
        store.undo()
        waitFor(store) { store.picks.isEmpty }
    }

    /// Ticking an old task picks it up first, and ⌘Z reopens it and releases the pick together.
    func testTickingAnOldTaskPicksItUpAndUndoTakesBothBack() throws {
        let store = try storeWithAnOldSitting()
        let before = try String(contentsOfFile: XCTUnwrap(store.notesPath), encoding: .utf8)
        mutateAndWait(store) { done in
            store.complete(try! self.task("Email Dana", in: store), advanceFocus: false, then: done)
        }
        XCTAssertEqual(try task("Email Dana", in: store).state, .done)
        XCTAssertNotNil(try task("Email Dana", in: store).picked)
        XCTAssertEqual(store.undoStack.count, 1)

        store.undo()
        try waitForFile(store) { $0 == before }
        waitFor(store) { store.picks.isEmpty }
        XCTAssertEqual(try events(store), [.picked, .released])
    }

    /// Adding a subtask to an old task is working on it now: the tree is picked up, the child lands under
    /// its parent where it was written, and ⌘Z takes the task and the pick back together.
    func testAddingASubtaskToAnOldTaskPicksUpItsTree() throws {
        let store = try storeWithAnOldSitting()
        let before = try String(contentsOfFile: XCTUnwrap(store.notesPath), encoding: .utf8)
        mutateAndWait(store) { done in
            store.addTodo(text: "Send the shortlist", relativeTo: try! self.task("Email Dana", in: store),
                          position: .child, then: done)
        }
        let child = try task("Send the shortlist", in: store)
        XCTAssertEqual(child.sessionIndex, try task("Email Dana", in: store).sessionIndex,
                       "The subtask is written under its parent, in the old sitting")
        XCTAssertEqual(child.depth, 1)
        XCTAssertEqual(PickLog.events(projectPath: try XCTUnwrap(store.projectPath)).map(\.task.text), ["Email Dana"],
                       "The pick names the tree's root")
        XCTAssertNotNil(child.picked)
        XCTAssertEqual(store.undoStack.count, 1)

        store.undo()
        try waitForFile(store) { $0 == before }
        waitFor(store) { store.picks.isEmpty }
    }

    /// What a project card scrolls to after its quick add: the task just added is the focused one by
    /// the time `then` runs. An old sitting is the hard case — the add starts a new one, and every
    /// "session:line" key shifts, so a before/after diff of keys would name every task on the card.
    func testAnUnanchoredAddIsFocusedWhenItsCompletionRuns() throws {
        let store = try store(withTasks: "Review the contract")
        let path = try XCTUnwrap(store.notesPath)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let heading = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("### ") })
        try text.replacingOccurrences(of: heading, with: "### Wed, Sep 2, 2026")
            .write(toFile: path, atomically: true, encoding: .utf8)
        try loadAndWait(store)
        let sittings = store.notes?.sessions.count
        var focused: String?
        mutateAndWait(store) { done in
            store.addTodo(text: "Call the caterer") {
                focused = store.focusedTodo.map(PMStore.key(for:))
                done()
            }
        }
        XCTAssertEqual(store.notes?.sessions.count, sittings.map { $0 + 1 },
                       "the fixture should make this add start a new sitting")
        XCTAssertEqual(focused, PMStore.key(for: try task("Call the caterer", in: store)))
    }

    func testAnUnanchoredAddToTodaysSittingIsFocusedToo() throws {
        let store = try store(withTasks: "First task\nSecond task")
        var focused: String?
        mutateAndWait(store) { done in
            store.addTodo(text: "Third task") {
                focused = store.focusedTodo.map(PMStore.key(for:))
                done()
            }
        }
        XCTAssertEqual(focused, PMStore.key(for: try task("Third task", in: store)))
    }

    /// A new task beside a top-level one is a new task of that sitting, not work on a tree.
    func testAddingBesideAnOldTopLevelTaskPicksNothingUp() throws {
        let store = try storeWithAnOldSitting()
        mutateAndWait(store) { done in
            store.addTodo(text: "Ask about parking", relativeTo: try! self.task("Book the venue", in: store),
                          position: .after, then: done)
        }
        XCTAssertNotNil(try? task("Ask about parking", in: store))
        XCTAssertTrue(store.picks.isEmpty)
    }

    /// Focus the app moved on its own is the app's choice, not yours, and picks nothing up.
    func testFocusAdvancingOnItsOwnPicksNothingUp() throws {
        let store = try storeWithAnOldSitting()
        mutateAndWait(store) { done in
            store.complete(try! self.task("Review the contract", in: store), advanceFocus: true, then: done)
        }
        XCTAssertEqual(store.todos.first(where: \.isFocused)?.text, "Email Dana")
        XCTAssertTrue(store.picks.isEmpty)
    }

    /// All or nothing: an undo whose document can't be written leaves the picks alone.
    func testAnUndoWhoseDocumentCannotBeWrittenLeavesThePicksAlone() throws {
        let store = try storeWithAnOldSitting()
        mutateAndWait(store) { done in store.focus(try! self.task("Email Dana", in: store), then: done) }
        let path = try XCTUnwrap(store.notesPath)
        let folder = (path as NSString).deletingLastPathComponent
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder)
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        }
        let failures = store.writeFailure?.token ?? 0
        store.undo()
        waitFor(store) { (store.writeFailure?.token ?? 0) > failures }
        XCTAssertEqual(try events(store), [.picked])
        XCTAssertEqual(store.undoStack.count, 1, "The step is still there to try again")
    }
}

// MARK: - A completion is always called

/// `reload` states the rule — "a completion that only ran on success would strand a caller waiting on
/// it the one time the read failed" — and four of the store's other completions broke it. Each returned
/// early without calling `then`, and the quick bar hands its receipt to `then`, so `>session` against a
/// project that wouldn't open left the bar waiting on an answer that never came.
///
/// Against a store that never loaded, because that is the state which takes every early return.
extension PMStoreTests {

    func testAMutationWithNoProjectOpenStillCompletesAndSaysWhy() {
        let store = PMStore(boundKey: nil)
        var completed = false
        store.appendSessionNote("anything") { completed = true }

        XCTAssertTrue(completed, "a caller waiting on the completion must not be stranded")
        XCTAssertEqual(store.writeFailure?.message, "No project is open, so nothing was written.",
                       "and it is a refused write, so a bar comparing failure tokens says so")
    }

    func testUndoingWithNothingToUndoStillCompletes() {
        let store = PMStore(boundKey: nil)
        var completed = false
        store.undoLast { completed = true }

        XCTAssertTrue(completed)
        XCTAssertNil(store.writeFailure,
                     "nothing to undo is not a failure — reporting it would notify from the background")
    }

    func testPastingNothingStillCompletes() {
        let store = PMStore(boundKey: nil)
        var completed = false
        store.pasteTasks([], after: nil) { completed = true }
        XCTAssertTrue(completed)
    }

    /// **The one a person could hit.** The quick bar's `>session` hands its receipt through here.
    func testASessionThatCannotBeOpenedIsReportedRatherThanLeftUnanswered() {
        let store = PMStore(boundKey: nil)
        var answered = false
        var index: Int? = 99
        store.openCurrentSession { answered = true; index = $0 }

        XCTAssertTrue(answered, "the bar's receipt rides on this completion")
        XCTAssertNil(index, "no session was opened, and the answer has to say so")
    }
}
