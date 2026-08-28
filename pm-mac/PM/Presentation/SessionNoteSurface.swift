import AppKit
import PmLib
import SwiftUI

private struct FooterHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// What a session note being written full screen needs to know, and nothing else.
///
/// Deliberately not `QuickBarModel`. The surface used to take one, back when going full screen was an
/// escalation of the quick bar's note mode; it isn't — it's its own surface with its own way in, and a
/// view that names the quick bar's model can't be stood up anywhere the quick bar isn't. That includes
/// the scratch harness this surface is tuned in, which is the practical half of the reason.
///
/// There is no save, no revert and no cancel here, by design. An edit is the note changing — `text`
/// going out through `onTextChanged` *is* the write — so the only thing the surface can do on the way
/// out is stop being on screen.
@MainActor
final class SessionNoteSurfaceModel: ObservableObject {
    /// The prose being edited. Bound straight into the editor, so this changes on every keystroke.
    @Published var text: String = "" {
        didSet {
            guard text != oldValue, !isApplyingExternalChange else { return }
            onTextChanged(text)
        }
    }
    @Published var projectName: String?
    /// Which session this is, in its own words — "Today" almost always, but the surface should say what
    /// it's actually pointed at rather than assume.
    @Published var sessionLabel: String = "Today"
    /// Where the note lives on disk. The editor needs it to write a pasted picture beside the note and
    /// to resolve relative links; without it a pasted image silently becomes nothing.
    @Published var noteURL: URL?

    /// Every edit, for the host to write through. Live and direct: there is no other save path.
    var onTextChanged: (String) -> Void = { _ in }
    /// Escape, or a click on the ground.
    var onClose: () -> Void = {}

    /// Put text in from *outside* — a reload, or the host seeding the surface — without it coming
    /// straight back out as an edit.
    ///
    /// Without this the write-through is a loop: the host writes the file, the store re-reads it and
    /// publishes, the new text lands here, `didSet` reports it as an edit, and the host writes again.
    private var isApplyingExternalChange = false
    func applyExternalChange(_ incoming: String) {
        guard incoming != text else { return }
        isApplyingExternalChange = true
        text = incoming
        isApplyingExternalChange = false
    }
}

/// The chrome row's height, measured rather than guessed. One reporter, so `max` is the right reduce —
/// never a bare assignment, which a non-reporting subtree would win with the default.
private struct ChromeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    func measuring<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == CGFloat {
        background(GeometryReader { geo in
            Color.clear.preference(key: key, value: geo.size.height)
        })
    }
}

/// A session note, full screen, on a dark ground: the prose and as little else as will still tell you
/// where you are.
///
/// **How it's placed, and why nothing here resizes.** The editor's frame is a constant — the screen,
/// less a margin at each end — whatever the note is. The eyeline is not a position the *frame* is moved
/// to; it's space inside the document, above the first line. So a short note renders its first line a
/// third of the way down and doesn't scroll, a growing note extends downward inside a frame that never
/// moves, and a long note fills the screen and scrolls. Nothing is measured, nothing is corrected, and
/// there is no moment on entry where the surface is the wrong size.
///
/// It began the other way round, with the frame sized to the prose so that the eyeline could give way
/// as the note grew. That can't be made to work: the prose's height is only known once the editor has
/// laid out, so every entry was a guess followed by a visible correction — a long note unfurling from
/// three lines, or a short one shrinking out of a full-height frame. Making the gap part of the
/// document instead removes the question rather than answering it faster.
///
/// **The header floats.** It sits over the top of the editor rather than above it, so the prose passes
/// underneath as you scroll instead of pushing it off the screen — the same arrangement the project
/// window's takeover uses for its own bar. It needs no reserved space of its own: at rest the first
/// line is already far below it.
///
/// The chrome fades while you type and comes back a moment after you stop. That's the whole of "minimal
/// UI" here — a header and a footer you can read when you look up, and prose alone when you don't.
/// Fading on a timer rather than on the pointer, because in a mode you entered in order to write, the
/// pointer is not where your attention is.
struct SessionNoteSurface: View {
    @ObservedObject var model: SessionNoteSurfaceModel
    @Environment(\.immersiveTuning) private var tuning

    /// How far down the note we're scrolled, so the chrome can ride with the prose and then stop.
    @State private var scrollY: CGFloat = 0
    /// The chrome row's own height. Seeded close and corrected on first layout — it decides only where
    /// the row itself sits, so a couple of points of correction moves nothing else.
    @State private var chromeHeight: CGFloat = 24
    /// Whether the last keystroke was recent enough to still count as writing.
    @State private var typing = false
    /// The pending "you've stopped" — replaced on every keystroke, so the chrome returns a fixed
    /// interval after the *last* one rather than after the first.
    @State private var settle: DispatchWorkItem?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                editor(in: geo.size)
                chrome(in: geo.size)
            }
            .frame(width: Self.measure)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, Self.topMargin)
            .padding(.bottom, Self.bottomMargin)
        }
        .onPreferenceChange(ChromeHeightKey.self) { chromeHeight = $0 }
        .onChange(of: model.text) { _ in noteTyping() }
        .onDisappear { settle?.cancel() }
    }

    // MARK: The prose

    private func editor(in size: CGSize) -> some View {
        // No overlay standing in for an empty note: the editor draws its own placeholder, on the
        // column its own first character will land on. It used to be a `Text` here, positioned by
        // adding up this view's insets — which got the eyeline right and the gutter wrong, so the
        // invitation began four characters to the left of the caret sitting in the middle of it.
        // See `MarkdownTextEditor.placeholder`.
        //
        // No `onContentHeight` and no `growthCeiling`: this editor is given its frame and keeps it.
        // Both of those exist for a host that grows with the prose, and this one deliberately
        // doesn't — which is also what lets the editor chase its own caret normally.
        //
        // No `onSubmit` either. There is nothing for ⌘↩ to commit when every keystroke is already
        // the write, and a key that claims to save implies there was a moment before it when the
        // note wasn't saved.
        MarkdownTextEditor(text: $model.text,
                           onCancel: model.onClose,
                           onScroll: { scrollY = $0 },
                           placeholder: "Write a note for today…",
                           textInset: Self.textInset,
                           noteURL: model.noteURL,
                           extraTopSpace: eyelineGap(in: size))
            .accessibilityLabel("Session note")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .mask(edgeFadeMask(height: size.height - Self.topMargin - Self.bottomMargin))
    }

    /// How far below the top of the editor the first line sits, so that it lands on the eyeline.
    ///
    /// Measured against the screen rather than against the column, and floored at nothing: on a short
    /// display the eyeline can fall above the top margin, and the answer there is simply no gap.
    private func eyelineGap(in size: CGSize) -> CGFloat {
        max(0, size.height * tuning.contentTopFraction - Self.topMargin - Self.textInset.height)
    }

    /// The prose's measure, and the same one the project window's takeover uses.
    ///
    /// A point value that means a character count: the note is set in a fixed-advance face, so its
    /// comfortable width is "about 78 columns" and can be stated exactly. Stated rather than derived
    /// from the screen, because a note set across a 27-inch display is a note whose lines your eye has
    /// to track all the way back — the extra width on a big screen belongs to the margins.
    private static let measure = MarkdownTextEditor.measureWidth

    private static let topMargin: CGFloat = 48
    private static let bottomMargin: CGFloat = 56
    /// The base clearance at both ends. The eyeline's gap is added to the top alone — see
    /// `MarkdownTextEditor.extraTopSpace`.
    private static let textInset = NSSize(width: 0, height: 10)

    /// Opaque through the middle, transparent at the very top and bottom.
    ///
    /// The prose is inset far more than the fade is deep, so at rest the gradient is over empty margin
    /// at both ends and the first and last lines are whole. It only ever touches text mid-scroll, which
    /// is the only time a fade should.
    @ViewBuilder
    private func edgeFadeMask(height: CGFloat) -> some View {
        let fade = min(tuning.edgeFade, max(1, height) / 3)
        if fade <= 0 {
            Rectangle()
        } else {
            let stop = fade / max(1, height)
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .black, location: stop),
                                   .init(color: .black, location: 1 - stop),
                                   .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    // MARK: The chrome, riding just above the prose

    /// One line, sitting a small gap above the first line of the note — and pinning to the top of the
    /// editor once you've scrolled that far.
    ///
    /// It was two rows before, one clamped to the top of the screen and one to the bottom. That framed
    /// the display rather than the note: with the first line a third of the way down, the header sat
    /// four hundred points from the thing it was labelling, and the footer was a status bar along the
    /// bottom edge. Both belong *to the note*, so both are here, on one line, where the note starts.
    ///
    /// Sticky in the proper sense: in flow until it would leave, then pinned. Scrolled past, it holds at
    /// the top edge and the prose passes underneath through the fade, so the surface never loses the one
    /// line saying where the writing is going.
    private func chrome(in size: CGSize) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 12, weight: .medium))
            Text(model.projectName ?? "No project")
            Text("·")
            Text(model.sessionLabel)
            Spacer(minLength: 12)
            // The one key that isn't guessable. Escape closes; everything else about this surface is
            // the editor's own and behaves as it does everywhere else in the app.
            Text("esc")
                .font(.caption.monospaced())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.10)))
            Text("done").font(.caption)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .measuring(ChromeHeightKey.self)
        .padding(.top, chromeTop(in: size))
        .frame(maxHeight: .infinity, alignment: .top)
        .opacity(chromeOpacity)
        .animation(Self.chromeFade, value: chromeOpacity)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.projectName ?? "No project"), \(model.sessionLabel). Escape: done")
    }

    /// Where the chrome sits, measured from the top of the editor: just above the first line, less
    /// however far you've scrolled, and never above the editor's own top edge.
    private func chromeTop(in size: CGSize) -> CGFloat {
        max(0, eyelineGap(in: size) - Self.chromeGap - chromeHeight - scrollY)
    }

    /// The breathing room between the chrome line and the first line of prose.
    private static let chromeGap: CGFloat = 12

    // MARK: Fading the chrome

    /// Hidden while writing, back a moment after you stop. Never hidden over an empty note — there the
    /// chrome is the only thing saying what the surface is for.
    private var chromeOpacity: Double {
        typing && !model.text.isEmpty ? 0 : 1
    }

    private func noteTyping() {
        typing = true
        settle?.cancel()
        let work = DispatchWorkItem { typing = false }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    /// Long enough to cover the pause at the end of a sentence, short enough that stopping to think
    /// brings the surface back before you've wondered where it went.
    private static let settleDelay: TimeInterval = 1.6

    /// Applied to the chrome's opacity, and to nothing else.
    ///
    /// It used to sit on the surface's root against `typing`. A root `.animation(_:value:)` doesn't only
    /// animate the property you had in mind — it animates every animatable change in the subtree
    /// whenever that value moves, and `typing` flips at exactly the moment the prose is changing.
    private static let chromeFade: Animation = .easeOut(duration: 0.35)
}
