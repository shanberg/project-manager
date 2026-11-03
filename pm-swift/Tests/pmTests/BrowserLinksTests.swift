import XCTest
@testable import PmLib

/// Whose page the browser's front tab is, from the projects' own links (docs/away-time.md).
final class BrowserLinksTests: XCTestCase {
    private let index = BrowserLinkIndex(projects: [
        (folder: "W-004 Design Editor", links: [
            LinkEntry(label: "Figma", url: "https://www.figma.com/design/Xk2abc/Grid-snapping"),
            LinkEntry(label: "Staging", url: "https://staging.designs.dev/"),
        ]),
        (folder: "H-004 Maxwell Carmody", links: [
            LinkEntry(label: "Slack", children: [
                LinkEntry(label: "#maxwell-carmody", url: "https://acme.slack.com/archives/C07MCAAAAA/p1671484233286559"),
            ]),
            LinkEntry(label: "Docs", url: "https://docs.google.com/document/d/1abcDEF/edit"),
        ]),
        (folder: "S-001 Self", links: [
            LinkEntry(label: "Figma home", url: "https://figma.com/"),
            LinkEntry(label: "Same doc", url: "https://docs.google.com/document/d/SHARED"),
        ]),
        (folder: "W-005 Brand", links: [
            LinkEntry(label: "Same doc", url: "https://docs.google.com/document/d/SHARED/edit"),
        ]),
    ])

    func testATabOnALinkedPageIsThatProjects() {
        XCTAssertEqual(index.match("https://figma.com/design/Xk2abc/Grid-snapping?node-id=1-2")?.project, "W-004 Design Editor")
        XCTAssertEqual(index.match("https://docs.google.com/document/d/1abcDEF/edit#heading=h.1")?.label, "Docs")
    }

    /// The web app's address and a shared message link name the same channel.
    func testASlackChannelMatchesByItsID() {
        XCTAssertEqual(index.match("https://app.slack.com/client/T04XYZ/C07MCAAAAA")?.project, "H-004 Maxwell Carmody")
        XCTAssertEqual(index.match("https://app.slack.com/client/T04XYZ/C07MCAAAAA/thread/C07MCAAAAA-1700")?.label,
                       "#maxwell-carmody")
        XCTAssertNil(index.match("https://app.slack.com/client/T04XYZ/C0OTHERCHAN"))
    }

    func testADirectMessageIsNobodysChannel() {
        XCTAssertNil(LinkKey("https://app.slack.com/client/T04XYZ/D07ABCDEFG").flatMap { key -> Bool? in
            key.isSlackChannel ? true : nil
        })
    }

    /// A bare host claims nothing: most projects share figma.com.
    func testALinkToABareHostNamesNoPage() {
        XCTAssertNil(index.match("https://figma.com/design/Other/File"))
        XCTAssertEqual(index.match("https://staging.designs.dev/")?.project, nil, "a host-only link names no page")
    }

    /// The more specific link wins; two projects at the same depth is nobody's.
    func testTheDeepestLinkWinsAndATieIsNobodys() {
        XCTAssertEqual(index.match("https://docs.google.com/document/d/SHARED/edit")?.project, "W-005 Brand")
        let tied = BrowserLinkIndex(projects: [(folder: "A", links: [LinkEntry(url: "https://x.com/p")]),
                                               (folder: "B", links: [LinkEntry(url: "https://x.com/p")])])
        XCTAssertNil(tied.match("https://x.com/p/q"))
    }

    func testOnlyWebAddressesAreLinks() {
        XCTAssertNil(LinkKey("obsidian://open?vault=PARA"))
        XCTAssertNil(LinkKey("not a url"))
    }

    // MARK: Sites that aren't work

    func testANotWorkDomainCoversItsSubdomains() {
        XCTAssertTrue(NotWorkSites.matches("https://m.youtube.com/watch?v=1", domains: ["youtube.com"]))
        XCTAssertTrue(NotWorkSites.matches("https://www.youtube.com/", domains: ["https://www.YouTube.com/feed"]))
        XCTAssertFalse(NotWorkSites.matches("https://notyoutube.com/", domains: ["youtube.com"]))
        XCTAssertFalse(NotWorkSites.matches("https://youtube.com/", domains: ["", "  "]))
    }

    // MARK: Channels nobody linked

    func testAChannelNameComesFromTheTabTitle() {
        XCTAssertEqual(slackChannelName(fromTitle: "brand-refresh (Channel) - Acme - Slack"), "brand-refresh")
        XCTAssertEqual(slackChannelName(fromTitle: "#ops (Private channel) - Acme - Slack"), "ops")
        XCTAssertNil(slackChannelName(fromTitle: "Pat Lee (DM) - Acme - Slack"))
    }

    /// Five minutes on two different days, not ten on one.
    func testAChannelIsWorthLinkingOnTwoDays() {
        var seen = ChannelSightings()
        seen.add(12, channel: "C1", day: "2026-11-02")
        XCTAssertFalse(seen.isWorthLinking("C1"))
        seen.add(3, channel: "C1", day: "2026-11-03")
        XCTAssertFalse(seen.isWorthLinking("C1"))
        seen.add(2, channel: "C1", day: "2026-11-03")
        XCTAssertTrue(seen.isWorthLinking("C1"))
    }
}
