import XCTest

/// What the address field offers while you type, and what it fills in.
final class CanvasAddressCompletionTests: XCTestCase {
    private typealias S = CanvasAddressSuggestions

    private let candidates: [S.Candidate] = [
        .init(title: "Open Issues", address: "https://github.com/acme/app/issues", source: .board),
        .init(title: "Acme Wiki", address: "https://wiki.acme.dev/home", source: .board),
        .init(title: "GitHub", address: "https://www.github.com/", source: .history),
        .init(title: "Gitlab Pipelines", address: "https://gitlab.com/acme/pipelines", source: .history),
        .init(title: "Dev server", address: "http://localhost:3000/", source: .history),
    ]

    func testNothingTypedOffersNothing() {
        XCTAssertEqual(S.matches("  ", in: candidates), [])
    }

    /// A host match beats a title match, and a board card beats history at the same level.
    func testRanksHostsThenBoardCards() {
        let found = S.matches("git", in: candidates).map(\.address)
        XCTAssertEqual(found.first, "https://github.com/acme/app/issues")
        XCTAssertEqual(Set(found), ["https://github.com/acme/app/issues", "https://www.github.com/",
                                    "https://gitlab.com/acme/pipelines"])
    }

    func testFindsTheStartOfATitleWord() {
        XCTAssertEqual(S.matches("iss", in: candidates).map(\.title), ["Open Issues"])
        XCTAssertEqual(S.matches("pipel", in: candidates).map(\.title), ["Gitlab Pipelines"])
    }

    /// The same page, reached two ways, is one row — and the board's.
    func testOneRowPerPage() {
        let twice = candidates + [.init(title: "Issues", address: "http://www.github.com/acme/app/issues/",
                                        source: .history)]
        let found = S.matches("github.com/acme", in: twice)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.source, .board)
    }

    /// The host first, keeping what you typed and the page's own scheme.
    func testCompletesTheHost() {
        let found = S.matches("git", in: candidates)
        XCTAssertEqual(S.completion(for: "Git", from: found),
                       .init(text: "Github.com", address: "https://github.com/"))
        XCTAssertEqual(S.completion(for: "local", from: S.matches("local", in: candidates)),
                       .init(text: "localhost:3000", address: "http://localhost:3000/"))
    }

    /// Past the host, the completion follows you into the path.
    func testCompletesThePath() {
        let found = S.matches("github.com/a", in: candidates)
        XCTAssertEqual(S.completion(for: "github.com/a", from: found),
                       .init(text: "github.com/acme/app/issues", address: "https://github.com/acme/app/issues"))
    }

    /// A `www.` the page has is kept on the way out even though you didn't type it.
    func testKeepsTheWWWYouSkipped() {
        let found = S.matches("github", in: [candidates[2]])
        XCTAssertEqual(S.completion(for: "github", from: found)?.address, "https://www.github.com/")
    }

    /// Words are a search, not an address to fill in.
    func testDoesNotCompleteWords() {
        XCTAssertNil(S.completion(for: "open iss", from: S.matches("open iss", in: candidates)))
        XCTAssertNil(S.completion(for: "iss", from: S.matches("iss", in: candidates)))
    }
}
