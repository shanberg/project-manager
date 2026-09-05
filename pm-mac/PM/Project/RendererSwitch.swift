import SwiftUI

/// Tasks or canvas, as one control that shows both.
///
/// This replaces a pair of buttons that were the same switch pointed two ways: a canvas glyph in the
/// project header that meant "show the board", and a list glyph in the board's header that meant "show
/// the tasks". Each was findable only once you were already on the other side of it, and neither said
/// there was another side — so the way back from a board was a symbol you had to recognise among five
/// other symbols, having never seen it before.
///
/// The answer is the Finder's view switcher: two states, both visible, the current one marked. You can
/// see where you are and where else you could be without having to already know.
///
/// Built from the header's own parts rather than from `Picker(.segmented)`, which was the first
/// attempt. A real segmented control brings a filled track and a raised pill, and inside a glass
/// capsule that already has chrome that reads as a control stuck onto the header rather than one
/// belonging to it. What is left is two of the capsule's ordinary symbol buttons with the current one
/// lifted onto a soft backing — the same idea, in the same voice as everything beside it.
///
/// Both headers render *this*, in the same place in the same capsule, so the control doesn't move when
/// you use it. That is most of why it works — a switcher that jumped from one end of the window to the
/// other as you pressed it would be two buttons again with extra steps.
struct RendererSwitch: View {
    let renderer: ProjectRenderer
    let select: (ProjectRenderer) -> Void

    /// Ties the two glyphs' backings together as one shape, so choosing slides it across rather than
    /// fading one out and another in. That is the difference between a pair of buttons that happen to
    /// be adjacent and a control with two positions.
    @Namespace private var backing

    var body: some View {
        HStack(spacing: 1) {
            segment(.tasks, symbol: "list.bullet", label: "Tasks")
            segment(.canvas, symbol: "rectangle.3.group", label: "Canvas")
        }
        .help("Show this project as tasks or as its canvas  (\u{2325}\u{2318}C)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Show project as"))
    }

    /// One position.
    ///
    /// The capsule's own vocabulary — a 12pt symbol at secondary strength in a hit area you don't have
    /// to aim at — with the current one lifted to full strength on a soft backing. A real segmented
    /// control brought a filled track and a raised pill of its own, which inside a glass capsule that
    /// already has chrome read as a control stuck onto the header rather than one belonging to it.
    ///
    /// Monochrome on purpose: the accent colour means "selected" on the board a few points below this,
    /// and a header that also used it for "current view" would be spending one signal on two facts.
    private func segment(_ which: ProjectRenderer, symbol: String, label: String) -> some View {
        let current = renderer == which
        return Button { select(which) } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(current ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 19)
                .contentShape(Rectangle())
                .background {
                    if current {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.quaternary)
                            .matchedGeometryEffect(id: "backing", in: backing)
                    }
                }
        }
        .buttonStyle(.plain)
        .animation(Motion.animation(.snappy(duration: 0.18)), value: renderer)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
    }
}
