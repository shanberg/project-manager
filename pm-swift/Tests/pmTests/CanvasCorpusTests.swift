import XCTest
@testable import PmLib

/// Every canvas in a real vault, read and written back, checked key by key for loss.
///
/// The synthetic fixtures in `CanvasTests` say the round-trip works for the shapes PM knows to look
/// for. Only a real vault says whether PM knows to look for the right shapes — the files there were
/// written by Obsidian and by whichever plugins the user has installed, in three different formats
/// with three different key orders, and that is a set of inputs no fixture is going to guess.
///
/// Skipped unless `PM_CANVAS_CORPUS` names a folder, because the corpus is somebody's notes and can't
/// live in the repository. Point it at a vault and run:
///
///     PM_CANVAS_CORPUS=~/Documents/PARA swift test --filter CanvasCorpusTests
///
/// **Read-only.** It never writes into the corpus — the written form is compared in memory.
@MainActor
final class CanvasCorpusTests: XCTestCase {

    func testEveryCanvasInTheCorpusSurvivesARoundTripWithNothingDropped() throws {
        let files = try corpus()
        try XCTSkipIf(files.isEmpty, "set PM_CANVAS_CORPUS to a folder holding .canvas files")

        var checked = 0
        for url in files {
            let original = try Data(contentsOf: url)
            let name = url.lastPathComponent

            let doc = try CanvasDocument.parse(original)
            let rewritten = Data(doc.serialized().utf8)

            // The model is stable: what PM read, wrote, and read again is what it read.
            XCTAssertEqual(try CanvasDocument.parse(rewritten), doc, "\(name): model changed on save")

            // And nothing was dropped: every key/value the file held is still there, unchanged. This
            // is the assertion that would catch a field PM forgot to write — comparing the two parsed
            // documents can't, because a key neither of them models is missing from both.
            assertNoLoss(before: try raw(original), after: try raw(rewritten), file: name)
            checked += 1
        }
        print("CanvasCorpusTests: \(checked) canvases round-tripped")
    }

    /// What the resolver actually recovers, on a real vault. Reports rather than asserts a rate: the
    /// number is a property of somebody's notes, not of this code, and a test that failed when a user
    /// deleted a file would be measuring the wrong thing. The assertion worth making is the one below
    /// it — a card PM claims to have found is a file that is really there.
    func testReportsHowManyFileCardsResolveInTheCorpus() throws {
        let files = try corpus()
        try XCTSkipIf(files.isEmpty, "set PM_CANVAS_CORPUS to a folder holding .canvas files")
        let root = URL(fileURLWithPath:
            (ProcessInfo.processInfo.environment["PM_CANVAS_CORPUS"]! as NSString).expandingTildeInPath)

        var found = 0, moved = 0, missing = 0
        for url in files {
            let doc = try CanvasDocument.read(contentsOf: url)
            let resolver = CanvasFileResolver(canvas: url, vaultRoot: root)
            for node in doc.nodes {
                guard case .file(let path, _) = node.content else { continue }
                switch resolver.resolve(path) {
                case .found: found += 1
                case .moved(let at, _):
                    moved += 1
                    XCTAssertTrue(FileManager.default.fileExists(atPath: at.path),
                                  "claimed to have followed \(path) to a file that isn't there")
                case .missing: missing += 1
                }
            }
        }
        let total = found + moved + missing
        print("""
        CanvasCorpusTests: \(total) file cards — \(found) where the canvas says, \
        \(moved) followed after a move, \(missing) unresolved
        """)
    }

    // MARK: -

    private func corpus() throws -> [URL] {
        guard let path = ProcessInfo.processInfo.environment["PM_CANVAS_CORPUS"], !path.isEmpty
        else { return [] }
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let walker = FileManager.default.enumerator(at: root,
                                                    includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles])
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "canvas" }.sorted {
            $0.path < $1.path
        }
    }

    private func raw(_ data: Data) throws -> [String: JSONValue] {
        let any = try JSONSerialization.jsonObject(with: data)
        return JSONValue(json: any).objectValue ?? [:]
    }

    /// Every key in `before` is present in `after` with the same value.
    ///
    /// Nodes and edges are matched by `id` rather than by position, so a writer that reordered them
    /// would still pass — reordering is not loss. Everything else is compared where it stands.
    private func assertNoLoss(before: [String: JSONValue], after: [String: JSONValue], file: String) {
        for (key, old) in before where key != "nodes" && key != "edges" {
            XCTAssertEqual(after[key], old, "\(file): top-level \"\(key)\" changed")
        }
        for key in ["nodes", "edges"] {
            let olds = before[key]?.arrayValue ?? []
            let news = Dictionary(
                (after[key]?.arrayValue ?? []).compactMap { value -> (String, [String: JSONValue])? in
                    guard let object = value.objectValue, let id = object["id"]?.stringValue
                    else { return nil }
                    return (id, object)
                },
                uniquingKeysWith: { first, _ in first })

            for old in olds {
                guard let fields = old.objectValue else { continue }
                guard let id = fields["id"]?.stringValue else {
                    XCTFail("\(file): a \(key) entry has no id")
                    continue
                }
                guard let written = news[id] else {
                    XCTFail("\(file): \(key) \(id) is missing after the round-trip")
                    continue
                }
                for (field, value) in fields {
                    XCTAssertEqual(written[field], value,
                                   "\(file): \(key) \(id) lost or changed \"\(field)\"")
                }
            }
        }
    }
}
