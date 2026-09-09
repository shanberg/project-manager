import SwiftUI

/// The readable-width cap: contents grow to `maxContentWidth` and then stop, sitting leading-aligned
/// in whatever pane width is left over, so a wide window turns into margin rather than very long rows.
///
/// Leading, not centred. The cap keeps rows readable in a wide window; centring the capped column on
/// top of that left the project name adrift in the middle of the pane, with no edge to line up against
/// and the sidebar's own content a long way off to its left.
///
/// This rides the column's contents — the header, the scrolling rows, the note editor — rather than
/// the column itself. Wrapped around the column, it capped everything inside including the header's
/// material bar, so dragging the window wider than the cap left the bar stopping short of the window's
/// edge while the pane kept going. Inside, each piece takes the cap where the cap belongs (the text)
/// and the bar spans the pane.
struct ReadableWidth: ViewModifier {
    /// How wide this content is allowed to get. Rows and the header that leads them take
    /// `maxListWidth`; prose takes the narrower `maxContentWidth` it defaults to.
    var cap: CGFloat = ProjectWindow.maxContentWidth

    /// The pane's width, measured once by whoever owns it and handed down.
    @Environment(\.pmColumnWidth) private var columnWidth

    /// The margin at each end of the ramp. `minGutter` is what even the narrowest window gives up —
    /// content is never flush against the pane's edges — and `maxGutter` is what a window with room to
    /// spare opens out to.
    ///
    /// Between `snug` and `roomy` it ramps, so dragging a window wider opens the margins gradually
    /// rather than snapping them open as it crosses one particular pixel; a step there is visible and
    /// reads as a glitch.
    private static let snug: CGFloat = 520
    private static let roomy: CGFloat = 760
    private static let minGutter: CGFloat = 6
    private static let maxGutter: CGFloat = 20

    /// The margin a column of this width carries. Static so the scroll view can ask for the same
    /// number for its bottom inset without a second copy of the ramp.
    static func gutter(for columnWidth: CGFloat) -> CGFloat {
        guard columnWidth > snug else { return minGutter }
        let t = min(1, (columnWidth - snug) / (roomy - snug))
        return (minGutter + (maxGutter - minGutter) * t).rounded()
    }

    /// The corner radius a row's selection band takes.
    ///
    /// A constant, because the band is now always standing in a margin — there is no width at which it
    /// runs flush to the pane's edges, so there is no width at which it should look like a stripe
    /// rather than a shape. This used to track the gutter, back when a narrow window had none.
    static let bandCornerRadius: CGFloat = 7

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: cap, alignment: .leading)
            // Outside the cap, not inside it: the gutter is margin the pane gives away, so a wide
            // window spends it on breathing room at the edges and still gets the full readable width
            // between them. Inside, it would have narrowed the text instead.
            .padding(.horizontal, Self.gutter(for: columnWidth))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ColumnWidthEnvironmentKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// The width of the project window's content column. Zero until the first measurement, which
    /// `ReadableWidth` reads as "no room to spare" — see `ReadableWidth.gutter(for:)`.
    var pmColumnWidth: CGFloat {
        get { self[ColumnWidthEnvironmentKey.self] }
        set { self[ColumnWidthEnvironmentKey.self] = newValue }
    }
}
