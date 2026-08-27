import XCTest
@testable import PmLib

/// The raw session delete stays raw on purpose.
///
/// Refusing a session that still holds tasks is `session.delete`'s rule, applied at the dispatcher
/// where the refusal has a message to carry (see `DryRunTests.testDeletingASessionWithTasksIsRefused`).
/// Keeping it out of the primitive leaves that usable by anything meaning to remove a session and its
/// contents together — which is what `testDeleteMiddleSessionKeepsNeighbours` relies on.
final class SessionDeleteGateTests: XCTestCase {
    func testThePrimitiveItselfStaysUnguarded() {
        let doc = """
        # P

        ## Sessions

        ### Wed, Aug 26, 2026

        - [ ] a task

        """
        XCTAssertNotNil(deleteSessionPreservingFormat(rawText: doc, sessionIndex: 0))
    }
}
