import XCTest
@testable import PmLib

/// Turning a stored `[[…]]` into the words a reader sees — including, when the caller can say, the
/// name the target goes by *now*.
final class WikilinkDisplayTests: XCTestCase {

    /// A vault where `W-1` has been retitled since the tokens were written.
    private let resolve: WikilinkResolver = { name in
        resolveWrittenName(name, in: [["W-1 Site Refresh", "H-4 Kitchen"], ["Team 1:1s"]])
    }

    // MARK: without a resolver — unchanged behaviour

    func testWithoutAResolverTheStoredNameIsShown() {
        XCTAssertEqual(displayingWikilinks("see [[W-1 Website Refresh]] now"),
                       "see W-1 Website Refresh now")
    }

    func testShorteningCodesDropsThePrefix() {
        XCTAssertEqual(displayingWikilinks("see [[W-1 Website Refresh]]", shorteningCodes: true),
                       "see Website Refresh")
    }

    /// An embed names a picture. A reader that turned `![[shot.png]]` into the bare word `shot.png`
    /// would be claiming a file is a sentence.
    func testEmbedsAreLeftAlone() {
        XCTAssertEqual(displayingWikilinks("![[shot.png]] and [[W-1 Site Refresh]]", resolving: resolve),
                       "![[shot.png]] and W-1 Site Refresh")
    }

    // MARK: with one — the rename becomes invisible

    func testAResolverShowsTheCurrentName() {
        XCTAssertEqual(displayingWikilinks("see [[W-1 Website Refresh]] now", resolving: resolve),
                       "see W-1 Site Refresh now")
    }

    /// The code prefix dropped is the *current* folder's, not the one somebody wrote down last year.
    func testResolutionHappensBeforeShortening() {
        XCTAssertEqual(displayingWikilinks("[[W-1 Website Refresh]]", shorteningCodes: true,
                                           resolving: resolve),
                       "Site Refresh")
    }

    /// A name that resolves to nothing is shown as written — `[[Dana]]` is a person, and there is
    /// nothing to improve about it.
    func testAnUnresolvedNameIsShownAsWritten() {
        XCTAssertEqual(displayingWikilinks("ask [[Dana]]", resolving: resolve), "ask Dana")
    }

    /// An alias is the words somebody chose to show. Neither a rename nor a preference overrules them.
    func testAnAliasIsLeftAlone() {
        XCTAssertEqual(displayingWikilinks("[[W-1 Website Refresh|the refresh]]", shorteningCodes: true,
                                           resolving: resolve),
                       "the refresh")
    }

    /// The offsets a row tints by: every token rewritten changes the string's length, so each one
    /// after it shifts. With a resolver the shift can be *negative* — the new name may be longer —
    /// which is the case the arithmetic had never seen.
    func testDisplayRangesLandOnTheirOwnNames() {
        let text = "a [[W-1 Website Refresh]] b [[Dana]] c"
        let display = displayingWikilinks(text, resolving: resolve)
        for range in wikilinkDisplayRanges(in: text, resolving: resolve) {
            let start = display.index(display.startIndex, offsetBy: range.offset)
            let end = display.index(start, offsetBy: range.length)
            XCTAssertEqual(String(display[start..<end]), range.name)
        }
    }

    // MARK: rewriting in place, brackets kept

    /// What the surfaces that hide brackets by *laying them out* need: the characters stay, so the
    /// layout manager can still turn each into the pill's padding and a click can still map a glyph
    /// back to a character index.
    func testResolvingKeepsTheBrackets() {
        XCTAssertEqual(resolvingWikilinks("see [[W-1 Website Refresh]] now", resolving: resolve),
                       "see [[W-1 Site Refresh]] now")
    }

    func testResolvingLeavesUnresolvedTokensAndEmbedsAlone() {
        XCTAssertEqual(resolvingWikilinks("![[shot.png]] ask [[Dana]]", resolving: resolve),
                       "![[shot.png]] ask [[Dana]]")
    }

    func testResolvingLeavesAnAliasAlone() {
        XCTAssertEqual(resolvingWikilinks("[[W-1 Website Refresh|the refresh]]", resolving: resolve),
                       "[[W-1 Website Refresh|the refresh]]")
    }

    /// A token that already names the folder is returned untouched, so nothing churns on every draw.
    func testResolvingIsIdempotent() {
        let once = resolvingWikilinks("see [[W-1 Website Refresh]]", resolving: resolve)
        XCTAssertEqual(resolvingWikilinks(once, resolving: resolve), once)
    }

    // MARK: shortening only where it stays unambiguous

    /// Two projects sharing a title. Dropping the code leaves two tokens both reading `Refresh`, and
    /// a click on either would then resolve to neither — so the code stays.
    private let colliding: WikilinkResolver = { name in
        resolveWrittenName(name, in: [["W-1 Refresh", "H-2 Refresh", "W-9 Launch"]])
    }

    func testShorteningKeepsTheCodeWhenTwoProjectsShareATitle() {
        XCTAssertEqual(resolvingWikilinks("[[W-1 Refresh]]", shorteningCodes: true, resolving: colliding),
                       "[[W-1 Refresh]]")
        XCTAssertEqual(displayingWikilinks("[[H-2 Refresh]]", shorteningCodes: true, resolving: colliding),
                       "H-2 Refresh")
    }

    /// And drops it where the title still names one project — so the code shows up exactly where it
    /// is doing work, and nowhere else. Two rows in one list can legitimately differ.
    func testShorteningDropsTheCodeWhereTheTitleIsUnique() {
        XCTAssertEqual(resolvingWikilinks("[[W-9 Launch]]", shorteningCodes: true, resolving: colliding),
                       "[[Launch]]")
        XCTAssertEqual(displayingWikilinks("a [[W-1 Refresh]] and [[W-9 Launch]]",
                                           shorteningCodes: true, resolving: colliding),
                       "a W-1 Refresh and Launch")
    }

    /// **The property the shortening rests on.** A pill drawn short is still a pill you can click:
    /// the name it shows is fed straight back to the same resolver, and has to land on the same
    /// folder. Without lenient resolution, shortening the pill would have broken navigating from it.
    func testAShortenedPillStillNavigatesBackToItsProject() {
        let groups = [["W-1 Site Refresh", "H-4 Kitchen"]]
        let resolve: WikilinkResolver = { resolveWrittenName($0, in: groups) }
        let drawn = resolvingWikilinks("[[W-1 Website Refresh]]", shorteningCodes: true, resolving: resolve)
        XCTAssertEqual(drawn, "[[Site Refresh]]")
        // What the label hands to navigation, and where it lands.
        let clicked = wikilinkDisplayName("[[Site Refresh]]")
        XCTAssertEqual(resolveWrittenName(clicked, in: groups), "W-1 Site Refresh")
    }

    /// An area carries no code, so there is nothing to drop and nothing to check.
    func testAnAreaIsUnchangedByShortening() {
        let resolve: WikilinkResolver = { resolveWrittenName($0, in: [["Team 1:1s"]]) }
        XCTAssertEqual(resolvingWikilinks("[[Team 1:1s]]", shorteningCodes: true, resolving: resolve),
                       "[[Team 1:1s]]")
    }

    /// A name PM can't place has no folder to check a short form against, so it keeps what was
    /// written — `[[Dana]]` is a person, and `[[W-9 Something]]` naming nothing is not an invitation
    /// to shorten it into `[[Something]]`.
    func testAnUnresolvedNameIsNotShortenedAgainstNothing() {
        let resolve: WikilinkResolver = { resolveWrittenName($0, in: [["W-1 Site Refresh"]]) }
        XCTAssertEqual(resolvingWikilinks("[[W-9 Something]]", shorteningCodes: true, resolving: resolve),
                       "[[W-9 Something]]")
    }

    /// With no resolver at all there is nothing to ask, so shortening is unconditional — what every
    /// caller did before one existed, and what the CLI still does.
    func testWithoutAResolverShorteningIsUnconditional() {
        XCTAssertEqual(displayingWikilinks("[[W-1 Refresh]]", shorteningCodes: true), "Refresh")
    }
}
