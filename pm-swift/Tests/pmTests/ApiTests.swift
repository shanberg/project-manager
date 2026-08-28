import XCTest
@testable import PmLib

/// The contract's own invariants: that what `pm api describe` publishes is what the dispatcher
/// actually enforces, that the diff describes an edit rather than each action describing itself, and
/// that a dry run is the same path as a write minus the write. See docs/api-contract.md.
final class ApiTests: XCTestCase {

    // MARK: Manifest

    func testManifestCoversEveryAction() throws {
        let manifest = apiManifest().objectValue
        let published = manifest?["actions"]?.arrayValue ?? []
        XCTAssertEqual(published.count, ApiRegistry.actions.count)
        XCTAssertEqual(manifest?["contractVersion"]?.stringValue, apiContractVersion)
        for entry in published {
            let object = entry.objectValue
            XCTAssertNotNil(object?["name"]?.stringValue)
            XCTAssertNotNil(object?["summary"]?.stringValue)
            XCTAssertNotNil(object?["input"]?.objectValue?["type"])
            let tier = object?["tier"]?.stringValue ?? ""
            XCTAssertNotNil(ApiTier(rawValue: tier), "unknown tier \(tier)")
        }
    }

    /// Every field the manifest publishes has to reach the validator, or its `required`, `allowed` and
    /// `minimum` are published promises nothing keeps.
    ///
    /// `fieldValues` is a hand-written mirror of `ApiInput`; adding a field to the contract without
    /// adding it there compiles, ships, and silently stops validating. That is how `kind` came to be
    /// published with two allowed values and checked against neither.
    func testEveryPublishedFieldIsValidated() {
        let seen = Set(fieldValues(ApiInput()).keys)
        for spec in ApiRegistry.actions {
            for field in spec.fields {
                XCTAssertTrue(seen.contains(field.name),
                              "\(spec.name).\(field.name) is published but never validated — add it to fieldValues")
            }
        }
    }

    /// The other half of it, from the outside: a value outside `allowed` is refused rather than
    /// falling back to a default.
    func testAValueOutsideAllowedIsRefused() {
        var input = ApiInput()
        input.title = "Bogus"
        input.kind = "nonsense"
        XCTAssertThrowsError(try performApi("project.create", input)) { error in
            guard let api = error as? ApiError else { return XCTFail("\(error)") }
            XCTAssertEqual(api.code, .invalidField)
            XCTAssertEqual(api.detail?.stringValue, "kind",
                           "the refusal should name the field that was wrong")
        }
    }

    func testActionNamesAreUniqueAndNamespaced() {
        let names = ApiRegistry.actions.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "duplicate action name")
        for name in names {
            XCTAssertTrue(name.contains("."), "\(name) should be namespaced")
        }
    }

    /// The published `required` list and the check that runs before an action are the same table.
    /// This is the property the whole design rests on, so it is asserted rather than assumed.
    func testSchemaRequiredMatchesWhatValidationEnforces() throws {
        for spec in ApiRegistry.actions {
            let required = Set((spec.inputSchema.objectValue?["required"]?.arrayValue ?? [])
                .compactMap(\.stringValue))
            XCTAssertEqual(required, Set(spec.fields.filter(\.required).map(\.name)), spec.name)

            guard !required.isEmpty else { continue }
            XCTAssertThrowsError(try performApi(spec.name, ApiInput()), spec.name) { error in
                guard let api = error as? ApiError else { return XCTFail("\(spec.name): \(error)") }
                XCTAssertEqual(api.code, .missingField, spec.name)
                XCTAssertTrue(required.contains(api.detail?.stringValue ?? ""),
                              "\(spec.name) complained about \(api.detail?.stringValue ?? "nothing")")
            }
        }
    }

    /// A task reference's shape is published, because a client that has to guess it will guess the
    /// positional half and skip the digest.
    func testTaskRefSchemaIsPublished() throws {
        let spec = ApiRegistry.spec("task.complete")!
        let task = spec.inputSchema.objectValue?["properties"]?.objectValue?["task"]?.objectValue
        let properties = task?["properties"]?.objectValue
        XCTAssertEqual(task?["type"]?.stringValue, "object")
        for key in ["session", "sessionOrdinal", "line", "digest"] {
            XCTAssertNotNil(properties?[key], "task reference should publish \(key)")
        }
    }

    // MARK: Refusals

    func testUnknownActionRefuses() {
        XCTAssertThrowsError(try performApi("task.finish")) { error in
            XCTAssertEqual((error as? ApiError)?.code, .unknownAction)
        }
    }

    /// Affordances are listed in the manifest and refused here, which is how the tier boundary is
    /// documented rather than merely observed.
    func testAffordancesAreListedAndRefused() {
        let affordances = ApiRegistry.actions.filter { $0.tier == .affordance }
        XCTAssertFalse(affordances.isEmpty)
        for spec in affordances {
            XCTAssertThrowsError(try performApi(spec.name), spec.name) { error in
                XCTAssertEqual((error as? ApiError)?.code, .unsupportedAction, spec.name)
            }
        }
    }

    func testEnumFieldsAreChecked() {
        var input = ApiInput()
        input.project = "anything"
        input.text = "a task"
        input.anchor = TaskRefInput(session: "0", line: 0)
        input.position = "beside"
        XCTAssertThrowsError(try performApi("task.add", input)) { error in
            let api = error as? ApiError
            XCTAssertEqual(api?.code, .invalidField)
            XCTAssertEqual(api?.detail?.stringValue, "position")
        }
    }

    // MARK: Diff

    private func todo(_ text: String, line: Int, checked: Bool = false, depth: Int = 0,
                      due: String? = nil, focused: Bool = false) -> Todo {
        Todo(text: text, checked: checked, rawLine: "- [\(checked ? "x" : " ")] \(text)",
             context: "", depth: depth, sessionIndex: 0, lineIndex: line, isFocused: focused,
             dueDate: due, digest: taskDigest(text), sessionISODate: "2026-08-21")
    }

    func testDiffNamesEachKindOfChange() {
        let before = [todo("Alpha", line: 0, focused: true), todo("Beta", line: 1),
                      todo("Gamma", line: 2, due: "2026-09-01")]
        let after = [todo("Alpha", line: 0, checked: true), todo("Beta", line: 1, focused: true),
                     todo("Gamma", line: 2, due: "2026-10-01"), todo("Delta", line: 3)]
        let kinds = Set(diffTodos(before: before, after: after).map(\.kind))
        XCTAssertTrue(kinds.isSuperset(of: [.completed, .retimed, .focused, .unfocused, .added]))
    }

    /// A task that moved is the same task, not one removed and another added — which is what the
    /// digest match is for.
    func testDiffFollowsATaskThatMoved() {
        let before = [todo("Alpha", line: 0), todo("Beta", line: 1)]
        let after = [todo("New thing", line: 0), todo("Alpha", line: 1), todo("Beta", line: 2)]
        let changes = diffTodos(before: before, after: after)
        XCTAssertEqual(changes.filter { $0.kind == .added }.count, 1)
        XCTAssertEqual(changes.first { $0.kind == .added }?.now, "New thing")
        XCTAssertTrue(changes.allSatisfy { $0.kind != .removed })
    }

    /// A rename can't be matched by digest, so it falls to the position match — otherwise it would
    /// read as a deletion and an unrelated addition.
    func testDiffSeesARenameRatherThanAnExchange() {
        let changes = diffTodos(before: [todo("Alpha", line: 0)], after: [todo("Alpha revised", line: 0)])
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.kind, .renamed)
        XCTAssertEqual(changes.first?.was, "Alpha")
        XCTAssertEqual(changes.first?.now, "Alpha revised")
    }

    func testDiffOfNothingIsEmpty() {
        let todos = [todo("Alpha", line: 0), todo("Beta", line: 1)]
        XCTAssertTrue(diffTodos(before: todos, after: todos).isEmpty)
    }

    // MARK: Summaries

    func testSummaryReadsInBothTenses() {
        let changes = [ApiChange(kind: .completed, ref: nil, now: "Review the contract"),
                       ApiChange(kind: .completed, ref: nil, now: "Read the redlines"),
                       ApiChange(kind: .focused, ref: nil, now: "Book the venue")]
        let phrase = summarize(action: "task.complete", changes: changes)
        XCTAssertEqual(phrase.sentence(dryRun: false),
                       "Completed “Review the contract” and 1 subtask. Focus moves to “Book the venue”.")
        XCTAssertEqual(phrase.sentence(dryRun: true),
                       "Would complete “Review the contract” and 1 subtask, moving focus to “Book the venue”.")
    }

    /// Adding a child task focuses it, and saying so twice in one sentence is noise.
    func testSummaryDropsARedundantFocusClause() {
        let changes = [ApiChange(kind: .added, ref: nil, now: "Check the appendix"),
                       ApiChange(kind: .focused, ref: nil, now: "Check the appendix")]
        XCTAssertEqual(summarize(action: "task.add", changes: changes).sentence(dryRun: true),
                       "Would add “Check the appendix”.")
    }

    /// An action with nothing to do reports a finding, and a finding has no future tense.
    func testStatementsDontTakeAWouldPrefix() {
        let phrase = Phrase.statement("Today's session was already there")
        XCTAssertEqual(phrase.sentence(dryRun: true), "Today's session was already there.")
        XCTAssertEqual(phrase.sentence(dryRun: false), "Today's session was already there.")
    }

    // MARK: Envelope

    func testRevisionTracksContentNotTime() {
        XCTAssertEqual(revision(of: "- [ ] Alpha"), revision(of: "- [ ] Alpha"))
        XCTAssertNotEqual(revision(of: "- [ ] Alpha"), revision(of: "- [x] Alpha"))
    }

    func testResultRoundTripsThroughJSON() throws {
        let result = ApiResult(action: "task.complete", summary: "Completed “Alpha”.",
                               revision: "abc123", changed: [ApiChange(kind: .completed, ref: nil, now: "Alpha")],
                               focus: TaskRefInput(session: "2026-08-21", line: 1, digest: "beef"),
                               relocated: true, dryRun: true)
        let data = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(ApiResult.self, from: data), result)
    }

    // MARK: Batches

    /// An action that takes either needs exactly one of them — a `required` list can't say that, and
    /// accepting both would force a rule about which wins.
    func testTaskOrTasksButNotBoth() {
        var neither = ApiInput()
        neither.project = "anything"
        XCTAssertThrowsError(try performApi("task.complete", neither)) { error in
            XCTAssertEqual((error as? ApiError)?.code, .missingField)
        }

        var both = ApiInput()
        both.project = "anything"
        both.task = TaskRefInput(session: "0", line: 0, digest: "abc")
        both.tasks = [TaskRefInput(session: "0", line: 1, digest: "def")]
        XCTAssertThrowsError(try performApi("task.complete", both)) { error in
            XCTAssertEqual((error as? ApiError)?.code, .missingField)
        }
    }

    func testAnEmptyBatchIsRefused() {
        var input = ApiInput()
        input.project = "anything"
        input.tasks = []
        XCTAssertThrowsError(try performApi("task.delete", input)) { error in
            let api = error as? ApiError
            XCTAssertEqual(api?.code, .invalidField)
            XCTAssertEqual(api?.detail?.stringValue, "tasks")
        }
    }

    /// The published schema has to say "one of these", or a client generated from it will believe
    /// `task` is required and never send a batch.
    ///
    /// Published as `allOf` of `oneOf`s rather than a bare `oneOf`, because an action can need more
    /// than one such choice — `task.setDue` needs two — and a schema can't carry two `oneOf` keys.
    func testTheSchemaPublishesTheChoice() throws {
        for name in ["task.complete", "task.reopen", "task.setDue", "task.delete"] {
            let spec = try XCTUnwrap(ApiRegistry.spec(name))
            XCTAssertTrue(spec.oneOf.contains(["task", "tasks"]), name)
            let schema = spec.inputSchema.objectValue
            let groups = schema?["allOf"]?.arrayValue ?? []
            XCTAssertEqual(groups.count, spec.oneOf.count, name)
            for (group, published) in zip(spec.oneOf, groups) {
                let choices = published.objectValue?["oneOf"]?.arrayValue ?? []
                XCTAssertEqual(choices.compactMap {
                    $0.objectValue?["required"]?.arrayValue?.first?.stringValue
                }, group, name)
            }
            let required = Set((schema?["required"]?.arrayValue ?? []).compactMap(\.stringValue))
            XCTAssertTrue(required.isDisjoint(with: ["task", "tasks"]),
                          "\(name) shouldn't require either of the pair on its own")
            XCTAssertTrue(required.contains("project"), "\(name) still needs a project")
            let list = schema?["properties"]?.objectValue?["tasks"]?.objectValue
            XCTAssertEqual(list?["type"]?.stringValue, "array", name)
            XCTAssertNotNil(list?["items"]?.objectValue?["properties"]?.objectValue?["digest"], name)
            XCTAssertNotNil(schema?["properties"]?.objectValue?["revision"], "\(name) should take a revision")
        }
    }

    /// "and 2 subtasks" is true of one task that took its children with it and false of three a
    /// person selected — the same count meaning two different things.
    func testABatchIsCountedNotNamed() {
        let changes = [ApiChange(kind: .completed, ref: nil, now: "Alpha"),
                       ApiChange(kind: .completed, ref: nil, now: "Beta"),
                       ApiChange(kind: .completed, ref: nil, now: "Gamma")]
        XCTAssertEqual(summarize(action: "task.complete", changes: changes, batch: true).sentence(dryRun: false),
                       "Completed 3 tasks.")
        XCTAssertEqual(summarize(action: "task.complete", changes: changes, batch: false).sentence(dryRun: false),
                       "Completed “Alpha” and 2 subtasks.")
    }

    /// Validation reads a bag of the input's fields by name. A field can be in the registry and on
    /// `ApiInput` and still be missing from that bag — in which case a required field is silently
    /// never checked, and an optional one is reported missing when it was given. Both have happened.
    func testEveryPublishedFieldIsVisibleToValidation() throws {
        var input = ApiInput()
        input.project = "p"
        input.text = "t"
        input.title = "t"
        input.domain = "W"
        input.prose = "n"
        input.label = "l"
        input.session = "0"
        input.key = "summary"
        input.value = .string("v")
        input.query = "q"
        input.entry = "e"
        input.now = "2026-08-22"
        input.due = "2026-09-01"
        input.waiting = "Website Refresh"
        input.task = TaskRefInput(session: "0", line: 0, digest: "abc")
        input.folder = "f"
        input.kind = "project"

        // Note what this can and can't catch. A *required* field the validator can't see shows up
        // here immediately, because nothing supplies it and the action reports it missing. An
        // *optional* one passes vacuously — an unset optional never trips `missingField` — which is
        // how `kind` came to be published with two allowed values and validated against neither.
        // `testEveryPublishedFieldIsValidated` is the half that catches those.
        for spec in ApiRegistry.actions where spec.tier != .affordance {
            // Given every field a value, nothing should be reported missing. What fails here is a
            // field the validator can't see, not a field the caller didn't send.
            //
            // Dry run, because this is checking validation and nothing past it. `validate` runs
            // ahead of the tier check and the write, so the flag costs this test no coverage — and
            // without it the loop reaches `project.create` with a title and a domain, which
            // succeeds against whatever vault the ambient config points at. That is not
            // hypothetical: it created a `W-0NN t` project in the real vault on every run.
            do {
                _ = try performApi(spec.name, input, options: ApiOptions(dryRun: true))
            } catch let error as ApiError where error.code == .missingField {
                XCTFail("\(spec.name): \(error.message)")
            } catch {
                // Anything else means validation passed and the action tried to run, which is all
                // this is checking.
            }
        }
    }

    /// The sweep above hands every action a valid title and domain, so `project.create` doesn't just
    /// validate — it runs, and it runs against whatever config the process is pointed at. Unnoticed,
    /// that put a `W-0NN t` project in the developer's real vault on every `swift test`.
    ///
    /// This pins the property that made it a leak rather than a bug: the sweep writes nothing. It
    /// runs the same loop against a vault of its own and asserts the vault stays empty, so dropping
    /// the `dryRun` flag fails here instead of showing up in someone's Documents folder weeks later.
    func testTheValidationSweepWritesNothing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let active = root.appendingPathComponent("Projects")
        let archive = root.appendingPathComponent("Archive")
        let areas = root.appendingPathComponent("Areas")
        for dir in [active, archive, areas] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let savedConfigHome = ProcessInfo.processInfo.environment["PM_CONFIG_HOME"]
        setenv("PM_CONFIG_HOME", root.path, 1)
        defer {
            if let saved = savedConfigHome { setenv("PM_CONFIG_HOME", saved, 1) }
            else { unsetenv("PM_CONFIG_HOME") }
        }
        try saveConfig(PmConfig(activePath: active.path, archivePath: archive.path,
                                areasPath: areas.path, domains: ["W": "Work"],
                                subfolders: ["docs"]))

        var input = ApiInput()
        input.project = "p"
        input.text = "t"
        input.title = "t"
        input.domain = "W"
        input.prose = "n"
        input.label = "l"
        input.session = "0"
        input.key = "summary"
        input.value = .string("v")
        input.query = "q"
        input.entry = "e"
        input.now = "2026-08-22"
        input.due = "2026-09-01"
        input.task = TaskRefInput(session: "0", line: 0, digest: "abc")
        input.folder = "f"
        input.kind = "project"

        for spec in ApiRegistry.actions where spec.tier != .affordance {
            _ = try? performApi(spec.name, input, options: ApiOptions(dryRun: true))
        }

        for dir in [active, archive, areas] {
            let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0 != ".DS_Store" }
            XCTAssertEqual(left, [],
                           "the validation sweep wrote \(left) into \(dir.lastPathComponent) — it must be a dry run")
        }
    }

    // MARK: Choices and ranges

    /// Set one of the fields a `oneOf` group names, by name.
    ///
    /// Deliberately a closed switch: a group naming a field this doesn't know fails loudly rather
    /// than passing vacuously, which is what a silent default would do.
    private func give(_ field: String, to input: inout ApiInput, file: StaticString = #filePath,
                      line: UInt = #line) {
        switch field {
        case "task": input.task = TaskRefInput(session: "0", line: 0, digest: "abc")
        case "tasks": input.tasks = [TaskRefInput(session: "0", line: 1, digest: "def")]
        case "due": input.due = "2026-12-01"
        case "clearDue": input.clearDue = true
        case "waiting": input.waiting = "Website Refresh"
        case "clearWaiting": input.clearWaiting = true
        case "limit": input.limit = 1
        case "sessionOrdinal": input.sessionOrdinal = 0
        default: XCTFail("no test value for \(field)", file: file, line: line)
        }
    }

    /// Every group, for every action: neither is refused and both are refused.
    ///
    /// Driven off the registry rather than a list of actions, because the bug this replaces was one
    /// group being checked while a second went unwritten — `task.setDue` took `due` and `clearDue`
    /// and, given neither, quietly read that as "clear it" and destroyed the date already there.
    func testEveryChoiceIsCheckedAndNotJustPublished() throws {
        for spec in ApiRegistry.actions where !spec.oneOf.isEmpty {
            for group in spec.oneOf {
                var neither = ApiInput()
                neither.project = "anything"
                for other in spec.oneOf where other != group { give(other[0], to: &neither) }
                XCTAssertThrowsError(try performApi(spec.name, neither),
                                     "\(spec.name) accepted none of \(group)") { error in
                    XCTAssertEqual((error as? ApiError)?.code, .missingField, spec.name)
                }

                var all = neither
                for field in group { give(field, to: &all) }
                XCTAssertThrowsError(try performApi(spec.name, all),
                                     "\(spec.name) accepted all of \(group)") { error in
                    XCTAssertEqual((error as? ApiError)?.code, .missingField, spec.name)
                }
            }
        }
    }

    /// The specific loss the pair above prevents: `task.setDue` used to treat a missing `due` as an
    /// instruction to clear, so a caller that meant to set a date and left the field out silently lost
    /// the one that was there.
    func testSettingADueDateWithoutSayingWhichWayIsRefused() {
        var input = ApiInput()
        input.project = "anything"
        input.task = TaskRefInput(session: "0", line: 0, digest: "abc")
        XCTAssertThrowsError(try performApi("task.setDue", input)) { error in
            let api = error as? ApiError
            XCTAssertEqual(api?.code, .missingField)
            XCTAssertEqual(api?.detail?.arrayValue?.compactMap(\.stringValue), ["due", "clearDue"])
        }
    }

    /// A published `minimum` is a checked one.
    ///
    /// Unchecked, these reach `prefix`/`suffix` or an array subscript and *trap* — which an adapter
    /// can't catch, so `pm mcp` died mid-session on `limit: -1` rather than refusing the one call.
    func testAPublishedRangeIsAnEnforcedRange() throws {
        var checked = 0
        for spec in ApiRegistry.actions {
            for field in spec.fields where field.minimum != nil {
                let minimum = field.minimum!
                let published = spec.inputSchema.objectValue?["properties"]?.objectValue?[field.name]?
                    .objectValue?["minimum"]?.intValue
                XCTAssertEqual(published, minimum, "\(spec.name).\(field.name) doesn't publish its range")

                var input = ApiInput()
                input.project = "anything"
                input.query = "anything"
                input.session = "0"
                input.label = "anything"
                for group in spec.oneOf { give(group[0], to: &input) }
                give(field.name, to: &input)
                switch field.name {
                case "limit": input.limit = minimum - 1
                case "sessionOrdinal": input.sessionOrdinal = minimum - 1
                default: XCTFail("no out-of-range value for \(field.name)")
                }
                XCTAssertThrowsError(try performApi(spec.name, input),
                                     "\(spec.name) accepted \(field.name) below \(minimum)") { error in
                    let api = error as? ApiError
                    XCTAssertEqual(api?.code, .invalidField, spec.name)
                    XCTAssertEqual(api?.detail?.stringValue, field.name, spec.name)
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0, "no ranged fields found — the test would pass on an empty sweep")
    }
}
