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
}
