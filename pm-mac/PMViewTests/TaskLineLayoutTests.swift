import AppKit
import SwiftUI
import XCTest

/// A task's words keep their width: badges share the line only while the words keep most of it, move
/// under the words past that, and a ghost control takes no room at all.
@MainActor
final class TaskLineLayoutTests: XCTestCase {
    private let words = "Migrate the press-release archive and make sure every PDF link still resolves"

    private func text(_ string: String) -> some View {
        Text(string)
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func badge(width: CGFloat) -> some View {
        Text("tomorrow").font(.system(size: 10)).frame(width: width)
    }

    private func height(_ view: some View, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true))
        return host.fittingSize.height
    }

    func testABadgeThatLeavesTheWordsMostOfTheLineSharesIt() {
        let alone = height(text("Pick a CMS"), width: 300)
        let line = height(TaskLineLayout {
            text("Pick a CMS")
            badge(width: 60)
        }, width: 300)
        XCTAssertEqual(line, alone, accuracy: 0.5, "a short task and its date stay on one line")
    }

    func testBadgesThatWouldSqueezeTheWordsGoUnderThem() {
        let alone = height(text(words), width: 200)
        let badgeHeight = height(badge(width: 80), width: 80)
        let line = height(TaskLineLayout {
            text(words)
            badge(width: 80)
        }, width: 200)
        // Beside the words they'd have left 114 of 200 points; under them the words keep all 200.
        XCTAssertEqual(line, alone + 1 + badgeHeight, accuracy: 0.5)
    }

    func testNoBadgesMeansTheWordsTakeTheWholeLine() {
        let alone = height(text(words), width: 200)
        let line = height(TaskLineLayout {
            text(words)
            HStack {}
        }, width: 200)
        XCTAssertEqual(line, alone, accuracy: 0.5)
    }

    /// The hover "＋date": drawn over the words' end, never costing them width or the row height.
    func testAGhostTakesNoRoom() {
        let alone = height(text(words), width: 200)
        let line = height(TaskLineLayout {
            text(words)
            HStack {}
            Color.red.frame(width: 150, height: 90)
        }, width: 200)
        XCTAssertEqual(line, alone, accuracy: 0.5)
    }
}
