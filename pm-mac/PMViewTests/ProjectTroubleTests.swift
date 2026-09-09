import XCTest

/// What a project window says when it cannot show you the project.
///
/// Three situations used to be answered by two different views and one whole alternate application.
/// The point of pinning them here is that they are now one decision with three outcomes, and that the
/// broken-canvas case is *not* among them — a canvas that will not parse is replaced (see
/// `PmLib.replaceUnreadableCanvas`), so what reaches the third branch is a vault that cannot be
/// written to.
final class ProjectTroubleTests: XCTestCase {
    /// No project, and the go-to-project hotkey is bound: the list beside this pane is already open, so
    /// the key is named as the other way there rather than as the instruction.
    func testNoProjectNamesTheListFirstAndTheKeySecond() {
        let message = ProjectTrouble.message(hasProject: false, errorMessage: nil,
                                             goToProjectKeys: "⌃Space")
        XCTAssertEqual(message.title, "No project open")
        XCTAssertEqual(message.detail, "Choose one from the list, or press ⌃Space.")
    }

    /// Most of the app's shortcuts ship unbound. With no key to name, the sentence still has to say
    /// something you can do.
    func testNoProjectAndNoBoundKeyStillPointsAtTheList() {
        let message = ProjectTrouble.message(hasProject: false, errorMessage: nil,
                                             goToProjectKeys: nil)
        XCTAssertEqual(message.detail, "Choose one from the list.")
    }

    /// A project that would not load says so, with the store's own words underneath rather than in
    /// place of a sentence — `errorMessage` is `String(describing:)` on a thrown error as often as it
    /// is prose, and that is a detail, not a headline.
    func testAProjectThatWouldNotLoadShowsItsError() {
        let message = ProjectTrouble.message(hasProject: true, errorMessage: "Invalid project.",
                                             goToProjectKeys: "⌃Space")
        XCTAssertEqual(message.title, "PM couldn't open this project.")
        XCTAssertEqual(message.detail, "Invalid project.")
    }

    /// A project that loaded fine and still has no board: the replacement was tried and failed, which
    /// means the folder cannot be written to.
    func testALoadedProjectWithNoBoardBlamesTheVault() {
        let message = ProjectTrouble.message(hasProject: true, errorMessage: nil,
                                             goToProjectKeys: nil)
        XCTAssertEqual(message.title, "PM couldn't make a canvas for this project.")
        XCTAssertEqual(message.detail, "Check that the vault is writable, then open the project again.")
    }
}
