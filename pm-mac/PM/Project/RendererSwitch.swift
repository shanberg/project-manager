import SwiftUI

/// Tasks or canvas, as one control that shows both.
///
/// This replaces a pair of buttons that were the same switch pointed two ways: a canvas glyph in the
/// project header that meant "show the board", and a list glyph in the board's header that meant "show
/// the tasks". Each was findable only once you were already on the other side of it, and neither said
/// there was another side — so the way back from a board was a symbol you had to recognise among five
/// other symbols, having never seen it before.
///
/// A segmented control is the Mac's answer to exactly this and has been since the Finder's view
/// switcher: two states, both visible, the current one marked. You can see where you are and where else
/// you could be without having to already know.
///
/// Both headers render *this*, in the same place in the same capsule, so the control doesn't move when
/// you use it. That is most of why it works — a switcher that jumped from one end of the window to the
/// other as you pressed it would be two buttons again with extra steps.
struct RendererSwitch: View {
    let renderer: ProjectRenderer
    let select: (ProjectRenderer) -> Void

    var body: some View {
        Picker("", selection: Binding(get: { renderer }, set: select)) {
            Image(systemName: "list.bullet")
                .accessibilityLabel(Text("Tasks"))
                .tag(ProjectRenderer.tasks)
            Image(systemName: "rectangle.3.group")
                .accessibilityLabel(Text("Canvas"))
                .tag(ProjectRenderer.canvas)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        // Its own width, not a share of the capsule's: everything in that row is sized by its content,
        // and a picker left to fill would take whatever the flexible items beside it didn't want.
        .fixedSize()
        .help("Show this project as tasks or as its canvas  (\u{2325}\u{2318}C)")
        .accessibilityLabel(Text("Show project as"))
    }
}
