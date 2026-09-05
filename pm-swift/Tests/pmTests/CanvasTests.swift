import XCTest
@testable import PmLib

/// Reading and writing an Obsidian canvas.
///
/// Most of these are round-trip assertions rather than field-by-field checks, because the risk this
/// code carries isn't getting a coordinate wrong — it's *silently dropping* what PM doesn't model. A
/// real vault's canvases are written by Obsidian and by at least two plugins, and the keys those write
/// are invisible to PM and load-bearing to them. So the question these ask, over and over, is: does
/// everything that went in come back out?
final class CanvasTests: XCTestCase {

    // MARK: Reading

    func testParsesEveryNodeKind() throws {
        let doc = try CanvasDocument.parse(Data("""
        {"nodes":[
          {"id":"a","type":"text","text":"# Hi","x":0,"y":0,"width":250,"height":60},
          {"id":"b","type":"file","file":"Projects/W-1 Site/docs/Notes.md","subpath":"#Today",
           "x":300,"y":0,"width":400,"height":400},
          {"id":"c","type":"link","url":"https://example.com","x":0,"y":100,"width":400,"height":400},
          {"id":"d","type":"group","label":"Frame","x":-20,"y":-20,"width":800,"height":600,"color":"4"}
        ],"edges":[
          {"id":"e","fromNode":"a","fromSide":"right","toNode":"b","toSide":"left"}
        ]}
        """.utf8))

        XCTAssertEqual(doc.nodes.count, 4)
        XCTAssertEqual(doc.nodes[0].content, .text("# Hi"))
        XCTAssertEqual(doc.nodes[1].content,
                       .file(path: "Projects/W-1 Site/docs/Notes.md", subpath: "#Today"))
        XCTAssertEqual(doc.nodes[2].content, .link(url: "https://example.com"))
        XCTAssertEqual(doc.nodes[3].content,
                       .group(label: "Frame", background: nil, backgroundStyle: nil))
        XCTAssertEqual(doc.nodes[3].color, "4")
        XCTAssertEqual(doc.nodes[1].frame, CanvasRect(x: 300, y: 0, width: 400, height: 400))

        XCTAssertEqual(doc.edges.count, 1)
        XCTAssertEqual(doc.edges[0].fromSide, .right)
        XCTAssertEqual(doc.edges[0].toSide, .left)
    }

    /// An edge that names neither end still draws one, because that's what the format means by
    /// leaving them out. Read back as nil so the writer doesn't add keys the file didn't have.
    func testEdgeEndsDefaultWithoutBeingWritten() throws {
        let doc = try CanvasDocument.parse(Data(
            #"{"nodes":[],"edges":[{"id":"e","fromNode":"a","toNode":"b"}]}"#.utf8))
        XCTAssertNil(doc.edges[0].toEnd)
        XCTAssertEqual(doc.edges[0].resolvedToEnd, .arrow)
        XCTAssertEqual(doc.edges[0].resolvedFromEnd, .none)
        XCTAssertFalse(doc.serialized().contains("toEnd"))
    }

    func testSizelessNodeGetsObsidiansDefaultCardSize() throws {
        let doc = try CanvasDocument.parse(Data(
            #"{"nodes":[{"id":"a","type":"text","text":"x","x":0,"y":0}],"edges":[]}"#.utf8))
        XCTAssertEqual(doc.nodes[0].frame.width, 250)
        XCTAssertEqual(doc.nodes[0].frame.height, 60)
    }

    /// A hand-edited canvas can hold `"color":4` where the format says `"4"`. Reading that as "no
    /// colour" would repaint the card on the next save.
    func testNumericColorIsReadAsItsStringForm() throws {
        let doc = try CanvasDocument.parse(Data(
            #"{"nodes":[{"id":"a","type":"text","text":"x","x":0,"y":0,"width":1,"height":1,"color":4}],"edges":[]}"#.utf8))
        XCTAssertEqual(doc.nodes[0].color, "4")
    }

    func testRejectsWhatIsntACanvas() {
        XCTAssertThrowsError(try CanvasDocument.parse(Data("not json".utf8)))
        XCTAssertThrowsError(try CanvasDocument.parse(Data("[1,2,3]".utf8)))
    }

    // MARK: Keeping what PM doesn't model

    /// The one that matters. Advanced Canvas's `styleAttributes`, the slides plugin's `sideRatio` and
    /// `isStartNode`, and Obsidian's `metadata` all have to survive a read and a write untouched.
    func testPluginKeysSurviveARoundTrip() throws {
        let original = """
        {"nodes":[
          {"id":"a","type":"text","styleAttributes":{"cardType":"cover","border":"invisible"},
           "text":"chasing a horse","x":2680,"y":2030,"width":400,"height":500},
          {"id":"g","type":"group","label":"Start Slide","isStartNode":true,
           "sideRatio":1.7777777777777777,"x":0,"y":0,"width":1200,"height":675}
        ],"edges":[
          {"id":"e","styleAttributes":{"pathfindingMethod":null},"fromNode":"a","toNode":"g"}
        ],"metadata":{"version":"1.0-1.0","frontmatter":{}}}
        """
        let doc = try CanvasDocument.parse(Data(original.utf8))
        let written = try CanvasDocument.parse(Data(doc.serialized().utf8))

        XCTAssertEqual(doc, written)
        XCTAssertEqual(written.nodes[0].extra["styleAttributes"],
                       .object(["cardType": .string("cover"), "border": .string("invisible")]))
        XCTAssertEqual(written.nodes[1].extra["sideRatio"], .number(1.7777777777777777))
        XCTAssertEqual(written.edges[0].extra["styleAttributes"],
                       .object(["pathfindingMethod": .null]))
        XCTAssertEqual(written.extra["metadata"],
                       .object(["version": .string("1.0-1.0"), "frontmatter": .object([:])]))
    }

    /// `isStartNode` is a boolean and has to come back a boolean. `JSONSerialization` hands `true`
    /// back as an `NSNumber` equal to 1, so the obvious reading turns it into `1` — which Obsidian
    /// still treats as true, which is why this would go unnoticed.
    func testBooleansDontDecayIntoNumbers() throws {
        let doc = try CanvasDocument.parse(Data("""
        {"nodes":[{"id":"g","type":"group","isStartNode":true,"x":0,"y":0,"width":1,"height":1}],
         "edges":[]}
        """.utf8))
        XCTAssertEqual(doc.nodes[0].extra["isStartNode"], .bool(true))
        XCTAssertTrue(doc.serialized().contains("\"isStartNode\":true"))
    }

    /// A node of a type this version has never heard of is kept whole and written back whole. A canvas
    /// with one new card in it should still open, and should still be safe to save.
    func testUnknownNodeKindIsCarriedThroughUntouched() throws {
        let doc = try CanvasDocument.parse(Data("""
        {"nodes":[
          {"id":"a","type":"text","text":"x","x":0,"y":0,"width":1,"height":1},
          {"id":"z","type":"whiteboard","strokes":[1,2,3],"x":9,"y":9,"width":9,"height":9}
        ],"edges":[]}
        """.utf8))

        XCTAssertEqual(doc.nodes.count, 1, "the unknown node isn't presented as a node")
        let text = doc.serialized()
        XCTAssertTrue(text.contains("\"whiteboard\""))
        XCTAssertTrue(text.contains("\"strokes\":[1,2,3]") || text.contains("\"strokes\":[\n"))
        XCTAssertFalse(text.contains("$pmUnparsedNodes"), "the parking key never reaches the file")
        XCTAssertEqual(try CanvasDocument.parse(Data(text.utf8)), doc)
    }

    // MARK: Writing

    /// Coordinates are whole numbers in the file and must stay whole numbers. Held as `Double`, they
    /// come back out as `-510.0` unless the writer looks — which would rewrite every line of every
    /// canvas PM ever saved.
    func testWholeNumbersStayWhole() throws {
        let doc = try CanvasDocument.parse(Data(
            #"{"nodes":[{"id":"a","type":"link","url":"https://x.dev","x":-510,"y":-535,"width":582,"height":1117}],"edges":[]}"#.utf8))
        let text = doc.serialized()
        XCTAssertTrue(text.contains("\"x\":-510"))
        XCTAssertFalse(text.contains("-510.0"))
        XCTAssertTrue(text.contains("\"height\":1117"))
    }

    /// Obsidian's shape: tabs, and one node per line so that moving a card is a one-line diff.
    func testWritesObsidiansLayout() throws {
        let doc = CanvasDocument(nodes: [
            CanvasNode(id: "a", content: .text("hi"), frame: CanvasRect(x: 0, y: 0, width: 250, height: 60)),
            CanvasNode(id: "b", content: .text("ho"), frame: CanvasRect(x: 0, y: 100, width: 250, height: 60)),
        ])
        let lines = doc.serialized().split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines[0], "{")
        XCTAssertEqual(lines[1], "\t\"nodes\":[")
        XCTAssertEqual(lines[2],
                       "\t\t{\"id\":\"a\",\"type\":\"text\",\"text\":\"hi\",\"x\":0,\"y\":0,\"width\":250,\"height\":60},")
        XCTAssertEqual(lines[4], "\t],")
        XCTAssertEqual(lines[5], "\t\"edges\":[]")
    }

    func testKeysGoOutInObsidiansOrderWithPluginKeysAfter() throws {
        let doc = try CanvasDocument.parse(Data("""
        {"nodes":[{"styleAttributes":{},"height":480,"width":539,"y":-457,"x":300,
          "file":"Projects/W-1 Site/docs/Notes.md","type":"file","id":"n"}],"edges":[]}
        """.utf8))
        XCTAssertTrue(doc.serialized().contains(
            #"{"id":"n","type":"file","file":"Projects/W-1 Site/docs/Notes.md","x":300,"y":-457,"width":539,"height":480,"styleAttributes":{}}"#))
    }

    /// Two writes of one document are the same bytes — otherwise every save is a diff even when
    /// nothing changed, and a canvas open in both PM and Obsidian never settles.
    func testWritingIsStable() throws {
        let doc = try CanvasDocument.parse(Data("""
        {"nodes":[{"id":"a","type":"text","text":"x","x":0,"y":0,"width":1,"height":1,
                   "styleAttributes":{"b":1,"a":2}}],
         "edges":[],"metadata":{"version":"1.0-1.0"}}
        """.utf8))
        XCTAssertEqual(doc.serialized(), doc.serialized())
        XCTAssertEqual(try CanvasDocument.parse(Data(doc.serialized().utf8)).serialized(),
                       doc.serialized())
    }

    func testTextIsEscapedNotMangled() throws {
        let doc = CanvasDocument(nodes: [
            CanvasNode(id: "a",
                       content: .text("Bonnie\n- \"5 cats\" — she said\\done\ttab"),
                       frame: CanvasRect(x: 0, y: 0, width: 1, height: 1)),
        ])
        let text = doc.serialized()
        XCTAssertTrue(text.contains("— she said"), "non-ASCII prose stays readable in the file")
        XCTAssertEqual(try CanvasDocument.parse(Data(text.utf8)).nodes[0].content,
                       .text("Bonnie\n- \"5 cats\" — she said\\done\ttab"))
    }

    func testEmptyCanvasRoundTrips() throws {
        let doc = try CanvasDocument.parse(Data(
            #"{"nodes":[],"edges":[],"metadata":{"version":"1.0-1.0","frontmatter":{}}}"#.utf8))
        XCTAssertTrue(doc.nodes.isEmpty)
        XCTAssertTrue(doc.serialized().contains("\"nodes\":[]"))
        XCTAssertEqual(try CanvasDocument.parse(Data(doc.serialized().utf8)), doc)
    }

    func testWritesToDiskAndReadsBack() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm-canvas-\(UUID().uuidString).canvas")
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = CanvasDocument(nodes: [
            CanvasNode(id: "a", content: .link(url: "https://example.com"),
                       frame: CanvasRect(x: 1, y: 2, width: 3, height: 4)),
        ])
        try doc.write(to: url)
        XCTAssertEqual(try CanvasDocument.read(contentsOf: url), doc)
    }

    // MARK: Geometry

    func testBoundsCoverEveryNodeIncludingGroups() {
        let doc = CanvasDocument(nodes: [
            CanvasNode(id: "a", content: .text("x"), frame: CanvasRect(x: 0, y: 0, width: 100, height: 100)),
            CanvasNode(id: "g", content: .group(label: "F", background: nil, backgroundStyle: nil),
                       frame: CanvasRect(x: -50, y: -50, width: 400, height: 400)),
        ])
        XCTAssertEqual(doc.bounds, CanvasRect(x: -50, y: -50, width: 400, height: 400))
        XCTAssertNil(CanvasDocument().bounds)
    }

    /// A group owns the cards wholly inside it, and no others. A card straddling the frame's edge
    /// belongs to the board, which is what makes dragging a frame predictable.
    func testGroupOwnsOnlyWhatIsWhollyInside() {
        let frame = CanvasRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertTrue(frame.contains(CanvasRect(x: 10, y: 10, width: 20, height: 20)))
        XCTAssertFalse(frame.contains(CanvasRect(x: 90, y: 10, width: 20, height: 20)))
        XCTAssertTrue(frame.intersects(CanvasRect(x: 90, y: 10, width: 20, height: 20)))
    }

    func testAnchorsSitOnTheNamedSide() {
        let node = CanvasNode(id: "a", content: .text("x"),
                              frame: CanvasRect(x: 100, y: 200, width: 400, height: 100))
        XCTAssertEqual(node.anchor(.left).x, 100)
        XCTAssertEqual(node.anchor(.left).y, 250)
        XCTAssertEqual(node.anchor(.top).x, 300)
        XCTAssertEqual(node.anchor(.top).y, 200)
        XCTAssertEqual(node.anchor(.bottom).y, 300)
        XCTAssertEqual(node.anchor(.right).x, 500)
    }

    func testIdsLookLikeObsidiansAndDontRepeat() {
        let ids = (0..<200).map { _ in CanvasID.make() }
        XCTAssertEqual(Set(ids).count, 200)
        XCTAssertTrue(ids.allSatisfy { $0.count == 16 && $0.allSatisfy("0123456789abcdef".contains) })
    }
}
