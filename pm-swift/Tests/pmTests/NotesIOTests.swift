import XCTest
@testable import PmLib

/// Shared note content used to test that both I/O paths read/write the same bytes.
private let alignmentFixtureContent = """
# Alignment Test

> [!summary] Summary
> A summary line.

> [!question] Problem
> Problem text.

> [!info] Goals
> 1.  First
> 2.  Second
> 3.  Third

> [!info] Approach
> Approach.

## Links

- Example: https://example.com

## Learnings

- One learning

## Sessions

### Mon, Mar 3, 2025

- [ ] Task one
- [x] Task two
- [ ] Task three
"""

final class NotesIOTests: XCTestCase {

    /// With useObsidianCLI false (or nil), makeNotesIO returns an IO that uses direct file I/O; read/write succeed.
    func testMakeNotesIONoObsidianConfigUsesDirectIO() throws {
        let config = PmConfig(
            activePath: "/tmp/active",
            archivePath: "/tmp/archive",
            domains: defaultDomains,
            subfolders: defaultSubfolders,
            useObsidianCLI: false
        )
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let path = tmp.path
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "# Hello".write(toFile: path, atomically: true, encoding: .utf8)

        let io = makeNotesIO(notesPath: path, config: config)
        let content = try io.readContent(path: path)
        XCTAssertEqual(content, "# Hello")

        try io.writeContent(path: path, content: "# Updated")
        let readBack = try io.readContent(path: path)
        XCTAssertEqual(readBack, "# Updated")
    }

    /// When Obsidian is configured but the CLI is not available, makeNotesIO falls back to
    /// DirectNotesIO; read/write still work.
    ///
    /// The probe is stubbed rather than left to the real one. Shelling out to `obsidian` made this
    /// test the machine's business: it took the fallback branch only where Obsidian was missing, and
    /// where it was installed it launched the app instead — which is how the suite came to hang for
    /// nineteen minutes on a cold run.
    func testMakeNotesIOObsidianConfiguredButCLIUnavailableFallsBackToDirectIO() throws {
        let config = PmConfig(
            activePath: "/tmp/active",
            archivePath: "/tmp/archive",
            domains: defaultDomains,
            subfolders: defaultSubfolders,
            useObsidianCLI: true,
            obsidianVault: "TestVault",
            obsidianVaultPath: "/tmp/vault"
        )
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let notesPath = tmpDir.appendingPathComponent("note.md").path
        try "# From direct".write(toFile: notesPath, atomically: true, encoding: .utf8)

        let io = makeNotesIO(notesPath: notesPath, config: config, isCLIAvailable: { false })
        XCTAssertTrue(io is DirectNotesIO, "No CLI means direct I/O, whatever the config asked for")
        let content = try io.readContent(path: notesPath)
        XCTAssertEqual(content, "# From direct")

        try io.writeContent(path: notesPath, content: "# Written via fallback")
        let readBack = try io.readContent(path: notesPath)
        XCTAssertEqual(readBack, "# Written via fallback")
    }

    /// The other branch of the same choice: a configured vault plus an available CLI selects the
    /// Obsidian path. Also stubbed, so it holds on a machine with no Obsidian at all.
    func testMakeNotesIOUsesObsidianWhenConfiguredAndAvailable() {
        let config = PmConfig(
            activePath: "/tmp/active",
            archivePath: "/tmp/archive",
            domains: defaultDomains,
            subfolders: defaultSubfolders,
            useObsidianCLI: true,
            obsidianVault: "TestVault",
            obsidianVaultPath: "/tmp/vault"
        )
        let io = makeNotesIO(notesPath: "/tmp/vault/note.md", config: config, isCLIAvailable: { true })
        XCTAssertTrue(io is ObsidianNotesIO)
    }

    // MARK: runProcess pipe draining

    /// A child with more than a pipe buffer's worth to say must still be collected in full — on both
    /// pipes at once, which is the case that pins the bug: draining only one still deadlocks on the
    /// other. Waiting for exit before reading held here forever, and `readViaCLI` returns whole notes
    /// files this way, so every project whose notes passed 64KB hung the app on open.
    ///
    /// Run off the main thread behind an expectation so a regression *fails* in thirty seconds rather
    /// than hanging the suite the way the original bug did.
    func testRunProcessCollectsOutputLargerThanThePipeBuffer() {
        let count = 200_000  // comfortably past the 64KB pipe buffer
        let finished = expectation(description: "runProcess returns")
        var result: (stdout: Data, stderr: Data, terminationStatus: Int32)?
        DispatchQueue.global().async {
            result = runProcess(
                executable: "/bin/sh",
                arguments: ["-c", "head -c \(count) /dev/zero | tr '\\0' 'x'; "
                                + "head -c \(count) /dev/zero | tr '\\0' 'y' >&2"]
            )
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)
        XCTAssertEqual(result?.stdout.count, count, "stdout collected in full")
        XCTAssertEqual(result?.stderr.count, count, "stderr collected in full")
        XCTAssertEqual(result?.terminationStatus, 0)
    }

    /// The same trap mirrored: a large `stdinData` written before the child is running blocks against
    /// a reader that hasn't started. Round-trips through `cat`, so the bytes back out prove the write
    /// completed rather than merely not hanging.
    func testRunProcessWritesStdinLargerThanThePipeBuffer() {
        let payload = Data(repeating: UInt8(ascii: "z"), count: 200_000)
        let finished = expectation(description: "runProcess returns")
        var result: (stdout: Data, stderr: Data, terminationStatus: Int32)?
        DispatchQueue.global().async {
            result = runProcess(executable: "/bin/cat", arguments: [], stdinData: payload)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)
        XCTAssertEqual(result?.stdout, payload, "every byte written reaches the child and comes back")
        XCTAssertEqual(result?.terminationStatus, 0)
    }

    /// readNotesFile and writeNotesFile with nil notesIO use direct I/O (backward compatibility).
    func testReadWriteNotesFileWithNilIOUsesDirectIO() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let path = tmp.path
        defer { try? FileManager.default.removeItem(at: tmp) }
        let templateContent = notesTemplate.replacingOccurrences(of: "{{title}}", with: "Direct")
        try templateContent.write(toFile: path, atomically: true, encoding: .utf8)

        let notes = try readNotesFile(notesPath: path, notesIO: nil)
        XCTAssertEqual(notes.title, "Direct")

        var updated = notes
        updated.summary = "Summary text"
        try writeNotesFile(notesPath: path, notes: updated, notesIO: nil)
        let readBack = try readNotesFile(notesPath: path, notesIO: nil)
        XCTAssertEqual(readBack.summary, "Summary text")
    }

    // MARK: - Alignment: both paths must read/write the same content

    /// Direct path: write then read with DirectNotesIO → content unchanged.
    func testAlignmentDirectPathRoundTrip() throws {
        let direct = DirectNotesIO()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let path = tmp.path
        defer { try? FileManager.default.removeItem(at: tmp) }

        try direct.writeContent(path: path, content: alignmentFixtureContent)
        let readBack = try direct.readContent(path: path)
        XCTAssertEqual(readBack, alignmentFixtureContent, "Direct path round-trip must preserve content")
    }

    /// Obsidian path (fallback): when path is outside vault, ObsidianNotesIO uses direct I/O; round-trip must match.
    func testAlignmentObsidianFallbackPathRoundTrip() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let path = tmpDir.appendingPathComponent("note.md").path
        let vaultPath = (tmpDir.path as NSString).appendingPathComponent("other-vault")
        let obsidian = ObsidianNotesIO(vaultName: "Vault", vaultPath: vaultPath)
        // path is tmpDir/note.md, vault is tmpDir/other-vault → path outside vault → fallback to direct I/O

        try obsidian.writeContent(path: path, content: alignmentFixtureContent)
        let readBack = try obsidian.readContent(path: path)
        XCTAssertEqual(readBack, alignmentFixtureContent, "Obsidian fallback path round-trip must preserve content")
    }

    /// Cross-path: write with DirectNotesIO, read with ObsidianNotesIO (fallback) → same content.
    func testAlignmentCrossPathWriteDirectReadObsidianFallback() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let path = tmpDir.appendingPathComponent("note.md").path
        let vaultPath = (tmpDir.path as NSString).appendingPathComponent("other")
        let direct = DirectNotesIO()
        let obsidian = ObsidianNotesIO(vaultName: "V", vaultPath: vaultPath)

        try direct.writeContent(path: path, content: alignmentFixtureContent)
        let readBack = try obsidian.readContent(path: path)
        XCTAssertEqual(readBack, alignmentFixtureContent, "Read via Obsidian fallback must see what Direct wrote")
    }

    /// Cross-path: write with ObsidianNotesIO (fallback), read with DirectNotesIO → same content.
    func testAlignmentCrossPathWriteObsidianFallbackReadDirect() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let path = tmpDir.appendingPathComponent("note.md").path
        let vaultPath = (tmpDir.path as NSString).appendingPathComponent("other")
        let direct = DirectNotesIO()
        let obsidian = ObsidianNotesIO(vaultName: "V", vaultPath: vaultPath)

        try obsidian.writeContent(path: path, content: alignmentFixtureContent)
        let readBack = try direct.readContent(path: path)
        XCTAssertEqual(readBack, alignmentFixtureContent, "Read via Direct must see what Obsidian fallback wrote")
    }

    /// Parsed alignment: same fixture via DirectNotesIO and via ObsidianNotesIO (fallback) parses to equal ProjectNotes.
    func testAlignmentParsedNotesEqualAcrossPaths() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let pathA = tmpDir.appendingPathComponent("a.md").path
        let pathB = tmpDir.appendingPathComponent("b.md").path
        let vaultPath = (tmpDir.path as NSString).appendingPathComponent("vault")
        let direct = DirectNotesIO()
        let obsidian = ObsidianNotesIO(vaultName: "V", vaultPath: vaultPath)

        try direct.writeContent(path: pathA, content: alignmentFixtureContent)
        try obsidian.writeContent(path: pathB, content: alignmentFixtureContent)

        let notesViaDirect = try readNotesFile(notesPath: pathA, notesIO: direct)
        let notesViaObsidian = try readNotesFile(notesPath: pathB, notesIO: obsidian)

        XCTAssertEqual(notesViaDirect.title, notesViaObsidian.title)
        XCTAssertEqual(notesViaDirect.summary, notesViaObsidian.summary)
        XCTAssertEqual(notesViaDirect.sessions.count, notesViaObsidian.sessions.count)
        XCTAssertEqual(serializeNotes(notesViaDirect), serializeNotes(notesViaObsidian), "Serialized notes must be identical for both paths")
    }
}
