import XCTest
import AppKit
@testable import PMViewTests

/// The header strip on a card that stands for a file or a page.
///
/// One thing is worth testing here and it isn't the drawing: whether the chip stays the height of its
/// own contents when it's put where it actually lives — the top of a `.fill` stack, above a preview
/// that fills the rest of the card. It didn't. Vertical hugging, which is what a header uses to say
/// "I am the size of my text", does nothing on a view that reports no intrinsic size, so the stack
/// handed the chip every spare point in the card and the preview got what was left. Behind a picture,
/// which reports no intrinsic size either, that was the whole card and the picture got none.
@MainActor
final class CanvasCardChipTests: XCTestCase {
    /// The card, built the way `CanvasFileNodeView` builds it: chip on top, body below, both pinned
    /// to the width, the stack pinned to all four edges of a card of a given size.
    private func card(height: CGFloat, body: NSView,
                      title: String = "Notes - Dnd - Strahd 2024.md",
                      warning: String? = nil) -> (chip: CanvasCardChip, body: NSView) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill

        let chip = CanvasCardChip(title: title, symbol: "doc.text", warning: warning)
        stack.addArrangedSubview(chip)
        chip.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(body)
        body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let card = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: height))
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        card.layoutSubtreeIfNeeded()
        return (chip, body)
    }

    /// A line of small type and the space around it — a caption, not a panel. Around 17pt, which on
    /// the smallest card anyone draws is still a small fraction of it.
    func testTheChipIsAboutAsTallAsItsText() {
        let chip = CanvasCardChip(title: "Notes.md", symbol: "doc.text", warning: nil)
        XCTAssertEqual(chip.intrinsicContentSize.height, 17, accuracy: 3)
        XCTAssertEqual(chip.intrinsicContentSize.width, NSView.noIntrinsicMetric)
    }

    /// The regression: in a tall card the chip keeps its own height and the body takes the rest.
    /// It used to take 334 of 400 and leave the note 66.
    ///
    /// A bare `NSView` stands for the preview, because the previews that matter — the hosted note,
    /// the PDF page, the picture — are all views that want the card. A plain label body would pass
    /// this for the wrong reason: it has an intrinsic height of its own and doesn't want filling, so
    /// it sits at 16pt whether the chip is behaving or not.
    func testTheChipDoesNotEatTheCard() {
        let (chip, body) = card(height: 400, body: NSView())
        XCTAssertEqual(chip.frame.height, chip.intrinsicContentSize.height, accuracy: 0.5)
        XCTAssertEqual(body.frame.height, 400 - chip.frame.height, accuracy: 0.5)
    }

    /// The starkest case, and the one you'd see first: a picture reports no intrinsic size either, so
    /// there was nothing to stop the chip taking all 400 points and giving the image none.
    func testAPictureStillGetsTheCard() {
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        let (chip, body) = card(height: 400, body: image)
        XCTAssertEqual(chip.frame.height, chip.intrinsicContentSize.height, accuracy: 0.5)
        XCTAssertGreaterThan(body.frame.height, 350)
    }

    /// A long name and a moved-path warning are truncated across the strip, not wrapped down it —
    /// the chip is the same height whatever it has to say.
    func testALongNameAndAWarningDoNotMakeItTaller() {
        let plain = CanvasCardChip(title: "A.md", symbol: "doc.text", warning: nil)
        let loud = CanvasCardChip(title: "Notes - A Very Long Project Name Indeed 2024.md",
                                  symbol: "doc.text",
                                  warning: "moved to Projects/C-002 Dnd - Strahd 2024/docs")
        XCTAssertEqual(loud.intrinsicContentSize.height, plain.intrinsicContentSize.height, accuracy: 0.5)
    }

    /// A card shorter than the chip is the one case where the chip has to give: the body is squeezed
    /// to nothing first, and the chip is clipped rather than pushing the card open.
    func testAShortCardDoesNotStretchTheChipEither() {
        let (chip, _) = card(height: 14, body: NSTextField(labelWithString: "A note."))
        XCTAssertLessThanOrEqual(chip.frame.height, chip.intrinsicContentSize.height + 0.5)
    }
}
