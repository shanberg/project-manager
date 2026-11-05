import XCTest

/// No new place reads a file's contents without saying why that's safe.
///
/// A read on main of a file in the vault is a freeze waiting for a stalled cloud provider (2026-11-05,
/// twice). The doors are `BackgroundFileRead` and `CloudFile` (bytes), `PictureStore` (pictures),
/// `CanvasFileQueue` / `CanvasStoreRegistry.load` (boards) and `CanvasProse` (card text). Any other
/// read says what makes it safe with a `// read:` comment on its line or the three above: off main,
/// or a file Folio owns that is always local.
final class FileReadGuardTests: XCTestCase {
    private static let reads = try! NSRegularExpression(pattern: [
        #"Data\(contentsOf:"#,
        #"String\(contentsOf(File)?:"#,
        #"CanvasDocument\.read\(contentsOf:"#,
        #"\.readContent\("#,
        #"NS(Dictionary|Array)\(contentsOf"#,
        #"FileHandle\(forReadingFrom"#,
    ].joined(separator: "|"))

    /// The doors themselves.
    private static let doors: Set<String> = ["CloudFile.swift", "Pictures.swift"]

    func testEveryFileReadSaysWhyItIsSafe() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PM")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !Self.doors.contains($0.lastPathComponent) }
        XCTAssertGreaterThan(files.count, 50, "didn't find the app's sources at \(sources.path)")

        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                guard Self.reads.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil else { continue }
                guard !lines[max(0, index - 3)...index].contains(where: { $0.contains("// read:") }) else { continue }
                offenders.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssert(offenders.isEmpty, """
            Read through BackgroundFileRead, PictureStore, CanvasFileQueue or CanvasProse, or say why \
            this one is safe with `// read:`:
            \(offenders.joined(separator: "\n"))
            """)
    }
}
