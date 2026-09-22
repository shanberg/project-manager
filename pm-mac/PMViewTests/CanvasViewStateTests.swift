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

    /// The sizes are the other half of an arrangement, and they were the half that went missing: a
    /// stack dragged into unequal heights got written down only if something *else* about the tiling
    /// changed afterwards. See `CanvasBoardView.rememberTileSizes`.
    func testTheSizesComeBackToo() {
        let sizes: [String: CanvasTiling.Size] = ["a": .pinned(320), "b": .flexible(2)]
        CanvasViewMemory.remember(
            CanvasViewState(tiling: .init(ids: ["a", "b"], arrangement: .masterStack,
                                          masterFraction: 0.5, sizes: sizes)),
            for: url)
        XCTAssertEqual(CanvasViewMemory.of(url).tiling?.sizes, sizes,
                       "a pin is a length and a share is a weight, and neither survives as the other")
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

    // MARK: Which workspace a board is in

    /// A board can be *in* a named workspace, and the name has to come back with the tiling or the
    /// window reopens unable to say which one it is showing — which is the whole of what §7b fixes.
    func testTheWorkspaceNameComesBackWithTheTiling() {
        CanvasViewMemory.remember(
            CanvasViewState(tiling: .init(ids: ["a", "b"], arrangement: .grid, masterFraction: 0.5),
                            workspaceName: "Dashboard"),
            for: url)
        XCTAssertEqual(CanvasViewMemory.of(url).workspaceName, "Dashboard")
    }

    /// The two come apart on purpose: a board left *untiled* still remembers the workspace it was in,
    /// so the next ⌘Return on the same cards resumes that workspace by name rather than starting an
    /// unnamed one with the same layout. See `CanvasBoardView.tile(_:)`.
    func testTheNameOutlivesTheTiling() {
        CanvasViewMemory.remember(
            CanvasViewState(workspaceName: "Dashboard",
                            lastTiling: .init(ids: ["a", "b"], arrangement: .grid,
                                              masterFraction: 0.5)),
            for: url)
        let back = CanvasViewMemory.of(url)
        XCTAssertNil(back.tiling, "not tiled")
        XCTAssertEqual(back.workspaceName, "Dashboard", "and still in Dashboard")
    }

    /// An unnamed workspace is the ordinary case, and it must stay indistinguishable from a board that
    /// predates workspaces having names — both are simply not in a named one.
    func testAnUnnamedWorkspaceStoresNoName() {
        CanvasViewMemory.remember(
            CanvasViewState(tiling: .init(ids: ["a"], arrangement: .grid, masterFraction: 0.5)),
            for: url)
        XCTAssertNil(CanvasViewMemory.of(url).workspaceName)
    }

    /// The literal bytes a build before §7b wrote. It decodes as an unnamed workspace, which is exactly
    /// what it was — the field is optional for this reason and not for tidiness.
    func testAStateWrittenBeforeNamesDecodesAsUnnamed() throws {
        let old = Data(#"""
        {"mode":"view","tiling":{"ids":["a","b"],"arrangement":"grid","masterFraction":0.5}}
        """#.utf8)
        let state = try JSONDecoder().decode(CanvasViewState.self, from: old)
        XCTAssertEqual(state.tiling?.ids, ["a", "b"])
        XCTAssertNil(state.workspaceName)
    }

    /// The order a lens reads in is remembered with the lens (docs/items.md D4) — and the default one
    /// is still nothing at all, so sorting a board and putting it back leaves no row behind.
    func testTheLensOrderComesBack() {
        CanvasViewMemory.remember(CanvasViewState(presentation: .list, sort: .name), for: url)
        let back = CanvasViewMemory.of(url)
        XCTAssertEqual(back.presentation, .list)
        XCTAssertEqual(back.sort, .name)

        CanvasViewMemory.remember(CanvasViewState(), for: url)
        XCTAssertNil(CanvasViewMemory.of(url).sort)
        XCTAssertNil(stored())
    }

    func testAStateWrittenBeforeTheLensesDecodesAsABoardInReadingOrder() throws {
        let old = Data(#"""
        {"mode":"view"}
        """#.utf8)
        let state = try JSONDecoder().decode(CanvasViewState.self, from: old)
        XCTAssertNil(state.presentation)
        XCTAssertNil(state.sort, "which the pane reads as reading order")
    }

    private func stored() -> Any? {
        (UserDefaults.standard.dictionary(forKey: "PMCanvasViewState"))?[url.path]
    }
}
