import XCTest
@testable import PMViewTests

/// Remembering how a board was being looked at, across launches.
///
/// The cases that matter are the ones where remembering could be *worse* than forgetting: a board
/// nobody touched acquiring a row anyway, and a tiling coming back in a different order from the one it
/// was left in.
final class CanvasViewStateTests: XCTestCase {

    private let url = URL(fileURLWithPath: "/tmp/pm-tests/\(UUID().uuidString).canvas")

    override func tearDown() {
        CanvasViewMemory.remember(CanvasViewState(), for: url)
        super.tearDown()
    }

    func testABoardNobodyTouchedIsNotRemembered() {
        CanvasViewMemory.remember(CanvasViewState(), for: url)
        XCTAssertEqual(CanvasViewMemory.of(url), CanvasViewState(),
                       "the default state reads back as the default whether or not it was stored")
        XCTAssertNil(stored(), "and it was not stored: a row saying \"the usual\" is a row for nothing")
    }

    /// The order is the arrangement — swapping two tiles changes nothing else — so it is the part a
    /// restore must not re-derive.
    func testATilingComesBackInTheOrderItWasLeft() {
        let tiling = CanvasViewState.Tiling(ids: ["c", "a", "b"], arrangement: .masterStack,
                                            masterFraction: 0.44)
        CanvasViewMemory.remember(CanvasViewState(mode: .connect, tiling: tiling), for: url)

        let back = CanvasViewMemory.of(url)
        XCTAssertEqual(back.mode, .connect)
        XCTAssertEqual(back.tiling?.ids, ["c", "a", "b"], "not sorted, not re-derived")
        XCTAssertEqual(back.tiling?.arrangement, .masterStack)
        XCTAssertEqual(back.tiling?.masterFraction, 0.44)
    }

    /// Leaving a tiling has to clear the memory of it, or every window on that board would open tiled
    /// forever after the one time you tiled it.
    func testLeavingATilingForgetsIt() {
        CanvasViewMemory.remember(
            CanvasViewState(tiling: .init(ids: ["a"], arrangement: .grid, masterFraction: 0.6)),
            for: url)
        CanvasViewMemory.remember(CanvasViewState(), for: url)
        XCTAssertNil(CanvasViewMemory.of(url).tiling)
        XCTAssertNil(stored())
    }

    private func stored() -> Any? {
        (UserDefaults.standard.dictionary(forKey: "PMCanvasViewState"))?[url.path]
    }
}
