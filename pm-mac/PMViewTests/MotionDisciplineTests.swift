import XCTest

/// Every animation in the app goes through `Motion` (Shared/Motion.swift), or says why it doesn't.
///
/// `Motion` is where Reduce Motion is honoured and where the app's tempos and curves live. A site that
/// writes its own literal duration, curve or travelling transition skips both, silently: it still
/// animates, it just slides for someone who asked it not to, at a speed nothing else uses. This reads
/// the sources rather than running them, so it catches the site the day it's written.
///
/// A site that is fine as it is — a pure fade, which Reduce Motion permits, or one that checks
/// `Motion.isReduced` itself — says so with a `// motion:` comment on its line or the three above.
final class MotionDisciplineTests: XCTestCase {

    /// Literal timing that bypasses `Motion`, and transitions that travel.
    private static let bypasses: [NSRegularExpression] = [
        #"CAMediaTimingFunction\(name:"#,
        #"\.duration *= *[0-9]"#,
        #"withAnimation\(\."#,
        #"\.animation\(\."#,
        #"\.transition\(\.(move|push|offset|scale|slide)"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    func testEveryAnimationGoesThroughMotionOrSaysWhy() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PM")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "Motion.swift" }
        XCTAssertGreaterThan(files.count, 50, "didn't find the app's sources at \(sources.path)")

        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                let range = NSRange(code.startIndex..., in: code)
                guard Self.bypasses.contains(where: { $0.firstMatch(in: code, range: range) != nil }),
                      !code.contains("Motion.") else { continue }
                let context = lines[max(0, index - 3)...index]
                guard !context.contains(where: { $0.contains("// motion:") }) else { continue }
                offenders.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssert(offenders.isEmpty, """
            Route these through Motion (Motion.duration, Motion.animation, Motion.moving, Motion.Tempo, \
            Motion.Curve), or mark a pure fade with `// motion: fade-only`:
            \(offenders.joined(separator: "\n"))
            """)
    }
}
