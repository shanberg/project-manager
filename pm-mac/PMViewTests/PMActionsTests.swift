import PmLib
import XCTest

/// The generated action list against the registry it was generated from.
///
/// **Why it compares against PmLib rather than against `pm api describe`.** The Raycast drift test
/// shells out to whatever `pm` binary it can find, because the extension talks to the contract over a
/// subprocess and that binary *is* its counterpart. The app's counterpart is different: it links
/// PmLib and calls the dispatcher in-process, so the thing it must not drift from is
/// `ApiRegistry.actions` in the library this test bundle is compiled against — not a binary on the
/// machine, which may be older, newer, or absent. This check is therefore stronger than the
/// TypeScript one and needs nothing installed to run.
final class PMActionsTests: XCTestCase {

    private var registryNames: Set<String> {
        Set(ApiRegistry.actions.map(\.name))
    }

    // MARK: Drift

    /// **The check the file exists for.** An action added to the contract and not regenerated here
    /// fails on the next test run, rather than when somebody finally calls it.
    func testEveryActionTheRegistryPublishesHasACase() {
        let generated = Set(PMAction.allCases.map(\.rawValue))
        let missing = registryNames.subtracting(generated).sorted()
        XCTAssertTrue(missing.isEmpty,
                      "the contract publishes \(missing.joined(separator: ", ")) with no case here — "
                      + "run `node pm-mac/scripts/generate-api-actions.mjs`")
    }

    /// And the other direction: a case for an action that no longer exists would compile, and fail
    /// only when called.
    func testEveryCaseNamesAnActionTheRegistryStillPublishes() {
        let generated = Set(PMAction.allCases.map(\.rawValue))
        let extra = generated.subtracting(registryNames).sorted()
        XCTAssertTrue(extra.isEmpty,
                      "\(extra.joined(separator: ", ")) is no longer in the contract — "
                      + "run `node pm-mac/scripts/generate-api-actions.mjs`")
    }

    func testTheGeneratedFileRecordsTheContractVersionItCameFrom() {
        XCTAssertEqual(generatedFromContractVersion, apiContractVersion,
                       "the generated file is from an older contract — regenerate it")
    }

    // MARK: What the enum carries

    func testEveryCaseAgreesWithTheRegistryAboutItsTier() {
        let tiers = Dictionary(uniqueKeysWithValues: ApiRegistry.actions.map { ($0.name, $0.tier) })
        for action in PMAction.allCases {
            XCTAssertEqual(action.tier, tiers[action.rawValue],
                           "\(action.rawValue) is filed under the wrong tier")
        }
    }

    /// Spot-checked as well as cross-checked, so that a bug making *both* sides agree on nonsense
    /// still fails.
    func testTheTiersAreTheOnesAPersonWouldExpect() {
        XCTAssertEqual(PMAction.taskList.tier, .query)
        XCTAssertEqual(PMAction.taskComplete.tier, .mutation)
        XCTAssertEqual(PMAction.appOpenWindow.tier, .affordance)
    }

    func testEveryCaseAgreesWithTheRegistryAboutItsRequiredFields() {
        let specs = Dictionary(uniqueKeysWithValues: ApiRegistry.actions.map { ($0.name, $0) })
        for action in PMAction.allCases {
            let spec = try? XCTUnwrap(specs[action.rawValue])
            let required = (spec?.fields ?? []).filter(\.required).map(\.name).sorted()
            XCTAssertEqual(action.requiredFields.sorted(), required,
                           "\(action.rawValue) disagrees about what it needs")
        }
    }

    func testEveryCaseAgreesWithTheRegistryAboutItsExclusiveGroups() {
        let specs = Dictionary(uniqueKeysWithValues: ApiRegistry.actions.map { ($0.name, $0) })
        for action in PMAction.allCases {
            let expected = (specs[action.rawValue]?.oneOf ?? []).map { $0.sorted() }.sorted { $0.first ?? "" < $1.first ?? "" }
            let actual = action.exclusiveGroups.map { $0.sorted() }.sorted { $0.first ?? "" < $1.first ?? "" }
            XCTAssertEqual(actual, expected, "\(action.rawValue) disagrees about its one-of groups")
        }
    }

    /// The two the contract doc names by hand, so the generator having silently dropped `allOf`
    /// parsing would be caught by something other than a comparison with itself.
    func testTheActionsThatTakeEitherOfTwoFieldsSaySo() {
        XCTAssertEqual(PMAction.taskSetDue.exclusiveGroups.map { $0.sorted() }.sorted { $0[0] < $1[0] },
                       [["clearDue", "due"], ["task", "tasks"]])
        XCTAssertTrue(PMAction.taskList.exclusiveGroups.isEmpty)
    }

    // MARK: The input completeness check

    /// `givenFieldNames` is what the debug-build assertion in `PMContract.perform` reads, so it has to
    /// tell a field that was set from one that was left nil — including one deliberately set to an
    /// empty string, which is a value rather than an absence.
    func testAnInputReportsExactlyTheFieldsItSets() {
        var input = ApiInput()
        XCTAssertTrue(input.givenFieldNames.isEmpty)

        input.project = "W-1"
        XCTAssertEqual(input.givenFieldNames, ["project"])

        input.due = "2026-09-12"
        XCTAssertEqual(input.givenFieldNames, ["project", "due"])

        input.text = ""
        XCTAssertTrue(input.givenFieldNames.contains("text"),
                      "an empty string is a value that was given, not a field left unset")

        input.project = nil
        XCTAssertFalse(input.givenFieldNames.contains("project"))
    }

    /// A false negative here would make the assertion useless, and a false positive would trap on
    /// correct calls — so check a real action's real requirements both ways.
    func testARealActionsRequirementsAreMetOrNotAsExpected() {
        var complete = ApiInput()
        complete.project = "W-1"
        complete.text = "A task"
        for field in PMAction.taskAdd.requiredFields {
            XCTAssertTrue(complete.givenFieldNames.contains(field),
                          "task.add needs \(field) and this input sets it")
        }

        let empty = ApiInput()
        XCTAssertFalse(PMAction.taskAdd.requiredFields.allSatisfy(empty.givenFieldNames.contains),
                       "an empty input should not satisfy task.add")
    }
}
