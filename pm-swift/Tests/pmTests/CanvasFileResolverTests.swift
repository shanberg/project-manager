import XCTest
@testable import PmLib

/// Finding the file a canvas card names after PM has moved it.
///
/// The fixture is a PARA vault with the drift already in it — a project sitting in the archive, one
/// renumbered into a different domain, one retitled — because every interesting case here is a stored
/// path that was correct when it was written and isn't now. A resolver tested only against a tidy
/// vault would pass while doing nothing.
@MainActor
final class CanvasFileResolverTests: XCTestCase {
    private var vault: URL!
    private var paths: ResolvedPaths!
    private var canvas: URL!

    override func setUpWithError() throws {
        vault = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm-canvas-vault-\(UUID().uuidString)")
        paths = ResolvedPaths(activePath: vault.appendingPathComponent("Projects").path,
                              archivePath: vault.appendingPathComponent("Archive").path,
                              areasPath: vault.appendingPathComponent("Areas").path)
        canvas = vault.appendingPathComponent("Boards/board.canvas")

        try put(".obsidian/app.json", "{}")
        try put("Boards/board.canvas", "{}")
        // In hand.
        try put("Projects/W-001 Site/docs/Notes.md", "site")
        // Finished and put away — a card written while it was active still says `Projects/…`.
        try put("Archive/W-002 Flexcompute/docs/Notes.md", "flexcompute")
        try put("Archive/W-002 Flexcompute/docs/media/Salary.pdf", "%PDF")
        // A standing responsibility.
        try put("Areas/Church/Sessions.md", "church")
        // One of a kind, filed somewhere a stored path doesn't name.
        try put("Attachments/Pasted image 20250306.png", "png")
        // The decoy, and the reason this fixture isn't tidy: when W-002 was renumbered out of the V
        // domain it freed `V-002`, and PM gave that number to the next V project. So a stored path
        // saying `V-002 …` now matches a real folder by code — the wrong one, with a real file at the
        // same relative path inside it.
        try put("Projects/V-002 Miles Jack Cake/docs/Notes.md", "cake")
        try put("Projects/V-002 Miles Jack Cake/docs/Sessions.md", "cake")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vault)
    }

    private func put(_ relative: String, _ contents: String) throws {
        let url = vault.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func resolver() -> CanvasFileResolver {
        CanvasFileResolver(canvas: canvas, vaultRoot: vault, paths: paths)
    }

    // MARK: The path is right

    func testAPathThatIsStillTrueIsFoundWhereItSays() {
        let found = resolver().resolve("Projects/W-001 Site/docs/Notes.md")
        XCTAssertEqual(found, .found(vault.appendingPathComponent("Projects/W-001 Site/docs/Notes.md")))
        XCTAssertFalse(found.hasMoved)
    }

    // MARK: The path has drifted

    /// The commonest case by far, and the one that broke nearly half the file cards in a real vault:
    /// the project finished and PM moved it to the archive. The stored path still says `Projects/`.
    func testAnArchivedProjectIsFollowedIntoTheArchive() {
        let found = resolver().resolve("Projects/W-002 Flexcompute/docs/Notes.md")
        XCTAssertEqual(found.url, vault.appendingPathComponent("Archive/W-002 Flexcompute/docs/Notes.md"))
        XCTAssertTrue(found.hasMoved, "the window should be able to offer to repair this")
    }

    /// Renumbered into another domain. The code changed, so the match is on the title.
    func testARenumberedProjectIsFollowedByItsTitle() {
        let found = resolver().resolve("Projects/V-002 Flexcompute/docs/media/Salary.pdf")
        XCTAssertEqual(found.url,
                       vault.appendingPathComponent("Archive/W-002 Flexcompute/docs/media/Salary.pdf"))
    }

    /// The case the tidy fixture missed. `V-002` now belongs to a different project, which has a file
    /// at the very same relative path — so reading the code first finds a real file that is the wrong
    /// one. The title is what still names the project the card meant.
    func testAReusedProjectCodeDoesNotHijackTheCard() {
        let found = resolver().resolve("Projects/V-002 Flexcompute/docs/Notes.md")
        XCTAssertEqual(found.url, vault.appendingPathComponent("Archive/W-002 Flexcompute/docs/Notes.md"),
                       "matched V-002 Miles Jack Cake, which merely inherited the number")
    }

    /// Retitled. The title changed, so the match is on the code — the half of the name that doesn't
    /// move, which is the whole reason PM can answer this and Obsidian can't.
    func testARetitledProjectIsFollowedByItsCode() {
        let found = resolver().resolve("Projects/W-002 Flexco Evaluation/docs/Notes.md")
        XCTAssertEqual(found.url, vault.appendingPathComponent("Archive/W-002 Flexcompute/docs/Notes.md"))
    }

    func testAnAreaIsFollowedByItsName() throws {
        try put("Areas/Church/Sessions.md", "church")
        let found = resolver().resolve("Projects/Church/Sessions.md")
        XCTAssertEqual(found.url, vault.appendingPathComponent("Areas/Church/Sessions.md"))
    }

    /// Nothing in the path names a project, but exactly one file in the vault has that name.
    func testAUniquelyNamedFileIsFoundAnywhereInTheVault() {
        let found = resolver().resolve("Projects/W-009 Gone/media/Pasted image 20250306.png")
        XCTAssertEqual(found.url, vault.appendingPathComponent("Attachments/Pasted image 20250306.png"))
    }

    // MARK: The path is wrong and guessing would be worse

    /// `Notes.md` exists in every project in a PARA vault. When the path names no project PM can
    /// follow, showing one project's notes on another's board would look right and be wrong, so the
    /// card reports missing instead.
    func testAnAmbiguousNameIsNotGuessedAt() {
        let found = resolver().resolve("Somewhere/Else/Notes.md")
        XCTAssertEqual(found, .missing)
    }

    func testAFileThatIsActuallyGoneIsMissing() {
        XCTAssertEqual(resolver().resolve("Projects/W-001 Site/docs/Deleted.png"), .missing)
        XCTAssertEqual(resolver().resolve(""), .missing)
    }

    /// A file card is only ever repaired to a path inside the vault, because that is the only kind of
    /// path the format can express.
    func testStorablePathIsVaultRelativeOrNothing() {
        let r = resolver()
        XCTAssertEqual(r.storablePath(for: vault.appendingPathComponent("Archive/W-002 Flexcompute/docs/Notes.md")),
                       "Archive/W-002 Flexcompute/docs/Notes.md")
        XCTAssertNil(r.storablePath(for: URL(fileURLWithPath: "/etc/hosts")))
    }

    /// Repairing a card means resolving it, then storing where it was found — so the two halves have
    /// to compose into a path that resolves cleanly next time.
    func testResolvingThenStoringYieldsAPathThatIsSimplyFound() throws {
        let r = resolver()
        let moved = r.resolve("Projects/W-002 Flexcompute/docs/Notes.md")
        let repaired = try XCTUnwrap(moved.url.flatMap { r.storablePath(for: $0) })
        XCTAssertEqual(resolver().resolve(repaired), .found(try XCTUnwrap(moved.url)))
    }

    // MARK: Freshness

    func testAnswersAreCachedAndRefreshForgetsThem() throws {
        let r = resolver()
        XCTAssertEqual(r.resolve("Projects/W-003 New/docs/Notes.md"), .missing)

        try put("Projects/W-003 New/docs/Notes.md", "new")
        XCTAssertEqual(r.resolve("Projects/W-003 New/docs/Notes.md"), .missing, "still the cached answer")

        r.refresh(paths: paths)
        XCTAssertEqual(r.resolve("Projects/W-003 New/docs/Notes.md"),
                       .found(vault.appendingPathComponent("Projects/W-003 New/docs/Notes.md")))
    }

    /// A canvas kept outside any vault has no vault-relative paths to resolve, and a relative path in
    /// one means what it says: beside the canvas. That reads as found, not moved.
    ///
    /// The fixture has to be genuinely outside a vault, not merely constructed with `vaultRoot: nil` —
    /// the initialiser looks one up when it isn't given one, which is exactly what it should do.
    func testOutsideAVaultAPathIsSimplyRelativeToTheCanvas() throws {
        let loose = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm-canvas-loose-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: loose) }
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        try "notes".write(to: loose.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        let r = CanvasFileResolver(canvas: loose.appendingPathComponent("board.canvas"),
                                   vaultRoot: nil, paths: paths)
        XCTAssertEqual(r.resolve("notes.md"), .found(loose.appendingPathComponent("notes.md")))
    }
}
