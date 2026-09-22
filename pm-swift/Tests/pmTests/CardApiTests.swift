import XCTest
@testable import PmLib

/// `card.list` and `card.add` — the board on the wire (docs/items.md D9).
///
/// Run in process against a real vault in a temporary folder, because the whole point of these two is
/// what they do to a file: a board that gets made when a project hasn't got one, a frame that gets made
/// when the label names none, and an arrangement that must not move because something was added to it.
final class CardApiTests: XCTestCase {
    private var root: String!
    private var savedConfigHome: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        for sub in ["active", "archive"] {
            try FileManager.default.createDirectory(atPath: (root as NSString).appendingPathComponent(sub),
                                                    withIntermediateDirectories: true)
        }
        savedConfigHome = ProcessInfo.processInfo.environment["PM_CONFIG_HOME"]
        setenv("PM_CONFIG_HOME", root, 1)
        let paths = ResolvedPaths(activePath: (root as NSString).appendingPathComponent("active"),
                                  archivePath: (root as NSString).appendingPathComponent("archive"),
                                  areasPath: (root as NSString).appendingPathComponent("areas"))
        try saveConfig(PmConfig(activePath: paths.activePath, archivePath: paths.archivePath,
                                domains: defaultDomains, subfolders: defaultSubfolders))
        let config = PmConfig(activePath: paths.activePath, archivePath: paths.archivePath,
                              domains: defaultDomains, subfolders: defaultSubfolders)
        _ = try createProject(config: config, paths: paths, domainCode: "W", title: "Redesign")
    }

    override func tearDownWithError() throws {
        // Restored rather than unset: unsetting drops every later test in the bundle back onto the
        // developer's real ~/.config/pm, which is how a test write reaches a real vault.
        if let savedConfigHome { setenv("PM_CONFIG_HOME", savedConfigHome, 1) } else { unsetenv("PM_CONFIG_HOME") }
        try? FileManager.default.removeItem(atPath: root)
        try super.tearDownWithError()
    }

    private func call(_ action: String, _ input: ApiInput, dryRun: Bool = false) throws -> ApiResult {
        var input = input
        if input.project == nil { input.project = "W-1" }
        return try performApi(action, input, options: ApiOptions(dryRun: dryRun, source: "test"))
    }

    private func add(_ text: String, frame: String? = nil, dryRun: Bool = false) throws -> ApiResult {
        var input = ApiInput()
        input.text = text
        input.frame = frame
        return try call("card.add", input, dryRun: dryRun)
    }

    private var board: CanvasDocument {
        get throws {
            let path = try XCTUnwrap(resolveProjectCanvasPath(
                projectPath: try resolveProjectPath(nameOrPrefix: "W-1")))
            return try CanvasDocument.parse(Data(contentsOf: URL(fileURLWithPath: path)))
        }
    }

    private func sections(_ result: ApiResult) -> [(frame: String?, titles: [String])] {
        guard case .object(let data)? = result.data, case .array(let sections)? = data["sections"] else {
            return []
        }
        return sections.compactMap { section in
            guard case .object(let group) = section, case .array(let items)? = group["items"] else { return nil }
            let frame: String? = { if case .string(let name)? = group["frame"] { return name }; return nil }()
            return (frame, items.compactMap { item in
                guard case .object(let card) = item, case .string(let title)? = card["title"] else { return nil }
                return title
            })
        }
    }

    // MARK: Reading

    /// A project that has never been given a board still answers the question. "What does this hold?"
    /// has an honest answer for an empty project, and it is "nothing" — not an error, and not a board
    /// brought into being by having been asked about.
    func testListingAProjectWithNoBoardAnswersNothingAndMakesNothing() throws {
        let result = try call("card.list", ApiInput())
        XCTAssertEqual(result.summary, "0 items in Redesign.")
        XCTAssertNil(try resolveProjectCanvasPath(projectPath: try resolveProjectPath(nameOrPrefix: "W-1")))
    }

    func testItemsComeGroupedByFrameWithTheLooseOnesFirst() throws {
        _ = try add("A loose thought")
        _ = try add("Chase the quote", frame: "Reference")
        // The Inbox was made first, so the loose section is empty and both cards are in frames.
        let listed = sections(try call("card.list", ApiInput()))
        XCTAssertEqual(listed.map(\.frame), ["Inbox", "Reference"])
        XCTAssertEqual(listed.map(\.titles), [["A loose thought"], ["Chase the quote"]])
    }

    func testOneFrameCanBeAskedForByName() throws {
        _ = try add("A loose thought")
        _ = try add("Chase the quote", frame: "Reference")
        var input = ApiInput()
        input.frame = "reference"
        let listed = sections(try call("card.list", input))
        XCTAssertEqual(listed.map(\.frame), ["Reference"], "matched without regard to case")
        XCTAssertEqual(listed.first?.titles, ["Chase the quote"])
    }

    func testTheSortIsReportedAndObeyed() throws {
        _ = try add("Zulu", frame: "Reference")
        _ = try add("Alpha", frame: "Reference")
        var input = ApiInput()
        input.sort = "name"
        let result = try call("card.list", input)
        XCTAssertEqual(sections(result).first?.titles, ["Alpha", "Zulu"])
        guard case .object(let data)? = result.data else { return XCTFail("no data") }
        XCTAssertEqual(data["sort"], .string("name"))
    }

    func testAnUnknownSortIsRefusedRatherThanIgnored() {
        var input = ApiInput()
        input.sort = "sideways"
        input.project = "W-1"
        XCTAssertThrowsError(try performApi("card.list", input)) { error in
            XCTAssertEqual((error as? ApiError)?.code, .invalidField)
        }
    }

    // MARK: Adding

    /// The Inbox is found by a mark and not by its name, and the mark has to survive the file for that
    /// to mean anything: two `card.add` calls are two separate reads of the board.
    func testARenamedInboxStillTakesTheNextCardAndIsNamedInTheSummary() throws {
        _ = try add("One")
        let canvasPath = try XCTUnwrap(resolveProjectCanvasPath(
            projectPath: try resolveProjectPath(nameOrPrefix: "W-1")))
        var document = try board
        let inbox = try XCTUnwrap(document.nodes.firstIndex { $0.isGroup })
        XCTAssertEqual(document.nodes[inbox].extra[CanvasItemPlacement.roleKey], .string("inbox"),
                       "written into the file, not held in memory")
        document.nodes[inbox].content = .group(label: "Reading", background: nil, backgroundStyle: nil)
        try document.write(to: URL(fileURLWithPath: canvasPath))

        XCTAssertEqual(try add("Two").summary, "Added a card to Reading in Redesign.")
        let after = try board
        XCTAssertEqual(after.nodes.filter(\.isGroup).count, 1, "no second Inbox beside it")
        XCTAssertEqual(after.nodes.filter { !$0.isGroup }.count, 2)
    }

    /// What you typed decides what it is, and the summary says which — a caller with no board in front
    /// of it has nothing else to read.
    func testAnAddressMakesAWebCardAndAnythingElseMakesATextCard() throws {
        XCTAssertEqual(try add("https://jsoncanvas.org").summary, "Added a web card to Inbox in Redesign.")
        XCTAssertEqual(try add("Ask legal about the DPA").summary, "Added a card to Inbox in Redesign.")
        let kinds = try board.nodes.filter { !$0.isGroup }.map(\.content.type)
        XCTAssertEqual(Set(kinds), ["link", "text"])
    }

    /// `roadmap.md` is a note about a roadmap, not a website in Moldova — see `canvasTypedAddress`.
    func testALineThatOnlyLooksLikeAHostIsStillProse() throws {
        _ = try add("roadmap.md")
        XCTAssertEqual(try board.nodes.first { !$0.isGroup }?.content.type, "text")
    }

    func testAddingMakesTheBoardWhenTheProjectHasntGotOne() throws {
        _ = try add("https://jsoncanvas.org")
        XCTAssertNotNil(try resolveProjectCanvasPath(projectPath: try resolveProjectPath(nameOrPrefix: "W-1")))
        XCTAssertEqual(try board.nodes.filter { !$0.isGroup }.count, 1)
    }

    func testAFrameIsMadeWhenItsLabelNamesNoneAndReusedAfterwards() throws {
        _ = try add("One", frame: "Reading")
        _ = try add("Two", frame: "reading")
        let frames = try board.nodes.filter(\.isGroup).map(canvasFrameLabel)
        XCTAssertEqual(frames, ["Reading"], "the second matched the first without regard to case")
    }

    /// The guard that matters most: adding from somewhere that cannot see the board must not move
    /// anything on it.
    func testNothingAlreadyOnTheBoardMoves() throws {
        _ = try add("First")
        let before = try board.nodes.filter { !$0.isGroup }
            .reduce(into: [String: CanvasRect]()) { $0[$1.id] = $1.frame }
        _ = try add("Second")
        let after = try board.nodes.reduce(into: [String: CanvasRect]()) { $0[$1.id] = $1.frame }
        for (id, frame) in before {
            XCTAssertEqual(after[id], frame, "\(id) moved")
        }
        XCTAssertEqual(try board.nodes.filter { !$0.isGroup }.count, 2)
        // The frame itself is allowed to grow to hold what was put in it, and nothing else may change.
        XCTAssertEqual(Set(before.keys).subtracting(after.keys), [], "nothing was taken away either")
    }

    func testAPreviewWritesNothingAndMakesNoBoard() throws {
        let preview = try add("https://jsoncanvas.org", dryRun: true)
        XCTAssertEqual(preview.summary, "Would add a web card to Inbox in Redesign.")
        XCTAssertTrue(preview.dryRun)
        XCTAssertNil(try resolveProjectCanvasPath(projectPath: try resolveProjectPath(nameOrPrefix: "W-1")))
    }

    func testAnEmptyLineIsRefused() {
        var input = ApiInput()
        input.text = "   "
        input.project = "W-1"
        XCTAssertThrowsError(try performApi("card.add", input)) { error in
            XCTAssertEqual((error as? ApiError)?.code, .invalidField)
        }
    }

    /// A board edit is a document write, so it is on the record and can be taken back — the property
    /// the contract's journal exists to give every surface.
    func testAddingIsJournaledAndCanBeReversed() throws {
        _ = try add("Ask legal about the DPA")
        XCTAssertEqual(try board.nodes.filter { !$0.isGroup }.count, 1)
        var undo = ApiInput()
        undo.project = "W-1"
        _ = try performApi("journal.undo", undo, options: ApiOptions(source: "test"))
        XCTAssertEqual(try board.nodes.filter { !$0.isGroup }.count, 0, "the card is gone again")
    }
}
