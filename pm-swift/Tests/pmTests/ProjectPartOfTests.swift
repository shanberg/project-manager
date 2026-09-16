import XCTest
import Foundation
@testable import PmLib

/// A project made of projects — docs/combining-projects.md.
final class ProjectPartOfTests: XCTestCase {

    // MARK: The stored value

    func testTheWrittenNameIsReadOutOfTheLink() {
        XCTAssertEqual(ProjectPartOf.writtenName(in: "[[S-004 Tool]]"), "S-004 Tool")
        XCTAssertEqual(ProjectPartOf.writtenName(in: "[[S-004 Tool|The tool]]"), "S-004 Tool")
        XCTAssertEqual(ProjectPartOf.writtenName(in: "S-004"), "S-004", "a hand-typed bare name")
        XCTAssertNil(ProjectPartOf.writtenName(in: "[[ ]]"))
    }

    /// Set, read back, cleared — and the file is exactly as it was when nothing else lived in the
    /// frontmatter.
    func testSettingAndClearingTouchesOnlyTheOneLine() {
        let raw = "# Member\n\n## Sessions\n"
        let set = settingProjectPartOf("S-004 Tool", in: raw)
        XCTAssertTrue(set.hasPrefix("---\npm-part-of: \"[[S-004 Tool]]\"\n---\n"))
        XCTAssertEqual(projectPartOf(rawText: set), "S-004 Tool")
        XCTAssertEqual(settingProjectPartOf(nil, in: set), raw)

        let withIcon = "---\npm-icon: leaf\n---\n# Member\n"
        let both = settingProjectPartOf("W-1 Big", in: withIcon)
        XCTAssertEqual(projectIcon(rawText: both), .symbol("leaf"))
        XCTAssertEqual(settingProjectPartOf(nil, in: both), withIcon)
    }

    // MARK: One level

    private let roots: [(scope: ProjectScope, folders: [String])] = [
        (.active, ["W-1 Big", "W-2 Part", "W-3 Other", "W-4 Nested"]),
        (.areas, ["Hiring"]),
        (.archive, ["W-9 Old"]),
    ]

    private func refusal(_ member: String, _ master: String,
                         _ memberships: [ProjectMembership] = []) -> PartOfRefusal? {
        do {
            _ = try checkedMaster(memberFolder: member, masterName: master,
                                  memberships: memberships, roots: roots)
            return nil
        } catch {
            return error as? PartOfRefusal
        }
    }

    func testAMasterResolvesByCodeTitleOrName() throws {
        XCTAssertEqual(try checkedMaster(memberFolder: "W-2 Part", masterName: "W-1", memberships: [], roots: roots),
                       "W-1 Big")
        XCTAssertEqual(try checkedMaster(memberFolder: "W-2 Part", masterName: "Hiring", memberships: [],
                                         roots: roots), "Hiring", "an area can be a master")
    }

    func testTheRefusals() {
        XCTAssertEqual(refusal("W-2 Part", "Nope"), .unknownMaster("Nope"))
        XCTAssertEqual(refusal("W-2 Part", "W-2"), .itself)
        XCTAssertEqual(refusal("W-2 Part", "W-9"), .masterIsArchived("W-9 Old"))

        let partOfBig = ProjectMembership(member: "W-2 Part", memberScope: .active, master: "W-1 Big",
                                          written: "W-1 Big")
        XCTAssertEqual(refusal("W-4 Nested", "W-2", [partOfBig]),
                       .masterIsAMember(master: "W-2 Part", itsMaster: "W-1 Big"),
                       "a member can't be a master")
        XCTAssertEqual(refusal("W-1 Big", "W-3", [partOfBig]),
                       .memberIsAMaster(member: "W-1 Big", members: ["W-2 Part"]),
                       "a master can't be a member")
        XCTAssertNil(refusal("W-3 Other", "W-1", [partOfBig]), "a second member is fine")
    }

    // MARK: Through the binary

    private static var pmBinaryPath: String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        return (root as NSString).appendingPathComponent(".build/debug/pm")
    }
    private var env: [String: String] = [:]
    private var tmp = ""

    override func tearDown() {
        if !tmp.isEmpty { try? FileManager.default.removeItem(atPath: tmp) }
        super.tearDown()
    }

    private func vault() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.pmBinaryPath))
        let fm = FileManager.default
        tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let config = (tmp as NSString).appendingPathComponent("config")
        let active = (tmp as NSString).appendingPathComponent("active")
        let areas = (tmp as NSString).appendingPathComponent("areas")
        let archive = (tmp as NSString).appendingPathComponent("archive")
        for path in [config, active, areas, archive] { try fm.createDirectory(atPath: path, withIntermediateDirectories: true) }
        let json: [String: Any] = ["activePath": active, "areasPath": areas, "archivePath": archive,
                                   "domains": ["W": "Work"], "subfolders": ["docs"]]
        try JSONSerialization.data(withJSONObject: json)
            .write(to: URL(fileURLWithPath: (config as NSString).appendingPathComponent("config.json")))
        env = ["PM_CONFIG_HOME": config, "PM_ACTIVE_PATH": active, "PM_AREAS_PATH": areas,
               "PM_ARCHIVE_PATH": archive]
        for title in ["Big", "Part", "Other"] { call("project.create", ["title": title, "domain": "W"]) }
        call("project.create", ["title": "Hiring", "kind": "area"])
    }

    @discardableResult
    private func call(_ action: String, _ input: [String: Any] = [:]) -> [String: Any] {
        let json = String(data: (try? JSONSerialization.data(withJSONObject: input)) ?? Data(), encoding: .utf8) ?? "{}"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.pmBinaryPath)
        process.arguments = ["api", "call", action, json]
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, e in e }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try? process.run()
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    private func get(_ project: String) -> [String: Any] {
        call("project.get", ["project": project])["data"] as? [String: Any] ?? [:]
    }

    func testMembersAndTheirMasterAreReportedFromBothSides() throws {
        try vault()
        call("project.setPartOf", ["project": "W-2", "partOf": "W-1"])
        call("project.setPartOf", ["project": "W-3", "partOf": "Big"])
        XCTAssertEqual(get("W-1")["members"] as? [String], ["W-2 Part", "W-3 Other"])
        XCTAssertEqual(get("W-2")["partOf"] as? String, "W-1 Big")

        call("project.setPartOf", ["project": "W-3", "clearPartOf": true])
        XCTAssertEqual(get("W-1")["members"] as? [String], ["W-2 Part"])
        XCTAssertTrue(get("W-3")["partOf"] is NSNull)
    }

    func testNestingIsRefusedWithTheReason() throws {
        try vault()
        call("project.setPartOf", ["project": "W-2", "partOf": "W-1"])
        let refused = call("project.setPartOf", ["project": "W-3", "partOf": "W-2"])
        let error = refused["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "invalidField")
        XCTAssertTrue((error?["message"] as? String ?? "").contains("one level"))
        XCTAssertTrue(get("W-3")["partOf"] is NSNull, "nothing was written")
    }

    /// An area has no code to be found by once its name changes, so renaming a master rewrites its
    /// members' links.
    func testRenamingAMasterAreaKeepsItsMembers() throws {
        try vault()
        call("project.setPartOf", ["project": "W-2", "partOf": "Hiring"])
        call("project.rename", ["project": "Hiring", "title": "Recruiting"])
        XCTAssertEqual(get("W-2")["partOf"] as? String, "Recruiting")
        XCTAssertEqual(get("Recruiting")["members"] as? [String], ["W-2 Part"])
    }
}
