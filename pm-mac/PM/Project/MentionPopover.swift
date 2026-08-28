import AppKit
import SwiftUI
import PmLib

/// The list a sigil puts up — projects and areas for `@`, line commands for `/` — picked with the
/// arrow keys and Return.
///
/// One list for both, because to the reader they are one interaction: a character summons a filtered
/// menu under the caret and Return takes what's highlighted. What differs is only what the rows mean,
/// which is the caller's business; this knows how to show rows and move a highlight.
///
/// A borderless child panel rather than an `NSPopover`, for one reason that decides the whole design:
/// **it must never take key focus.** The text view has to keep receiving every keystroke while this is
/// up, because what's being typed is simultaneously the query *and* the note. An `NSPopover` with a
/// focusable content view steals first responder and the next character lands in the wrong place.
/// So this panel is non-activating, is never made key, and owns no keyboard handling of its own —
/// `ShortcutTextView.keyDown` decides what ↑↓/⏎/⎋ mean and calls in.
///
/// It's a child window of the editor's window so it travels with it: a panel positioned once in screen
/// coordinates is in the wrong place the moment anybody moves the window under it.
@MainActor
final class MentionPopover {
    /// One row, as the list draws it. Deliberately display-only: the popover never learns what taking
    /// a row *does*, which is what lets projects and commands share it.
    struct Item: Equatable, Identifiable {
        let id: String
        let title: String
        /// The quiet half — a project's code, or the date a preset stands for.
        let detail: String?
        /// A note at the trailing edge, for something worth saying about the row itself.
        let trailing: String?
    }

    /// What the list is showing and where the highlight is. Published so the hosted SwiftUI redraws;
    /// owned here so the panel and the key handler read one source.
    final class Model: ObservableObject {
        @Published var items: [Item] = []
        @Published var selection = 0
    }

    private let model = Model()
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible == true }

    /// The index Return would take, if there is one. An index rather than a row, because the caller
    /// holds what the rows mean and this holds only how they look.
    var selectedIndex: Int? {
        model.items.indices.contains(model.selection) ? model.selection : nil
    }

    /// Show (or update) the list under `anchor`, given in the text view's own coordinates.
    ///
    /// An empty match list hides rather than showing an empty box. There is a real design question
    /// there — a mention that matches nothing is a *valid* thing to write in PM, unlike in Linear,
    /// because `waiting: [[Dana]]` names a person — and the answer for now is that the popover simply
    /// gets out of the way and lets the typing stand. See docs/links.md.
    /// Show (or update) the list under `anchor`, **in screen coordinates**.
    ///
    /// Screen, not view, because the one rect a text view will tell you about a character range is
    /// `firstRect(forCharacterRange:actualRange:)` — the `NSTextInputClient` method AppKit itself uses
    /// to place an input method's candidate window — and that is documented to be in screen space.
    /// Taking it as view or window coordinates and converting "up" to the screen lands the panel at an
    /// offset the size of the window's own origin, which on a window that isn't at (0,0) is somewhere
    /// nobody can see. The coordinate space is in the parameter name for exactly that reason.
    ///
    /// An empty match list hides rather than showing an empty box. There is a real design question
    /// there — a mention that matches nothing is a *valid* thing to write in PM, unlike in Linear,
    /// because `waiting: [[Dana]]` names a person — and the answer for now is that the popover gets out
    /// of the way and lets the typing stand. See docs/links.md.
    func show(_ items: [Item], screenAnchor anchor: NSRect, in view: NSView) {
        guard !items.isEmpty, let window = view.window else { return hide() }
        if items != model.items {
            model.items = items
            model.selection = 0
        }
        let panel = self.panel ?? makePanel(parent: window)
        let size = NSSize(width: 320, height: min(CGFloat(items.count), 6) * 26 + 12)
        // Below the caret line, flipped above it when there's no room below — the list should never
        // cover the words being typed to filter it.
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height - 4)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        if let visible {
            if origin.y < visible.minY { origin.y = anchor.maxY + 4 }
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible { panel.orderFront(nil) }
    }

    /// The panel's frame, for a caller checking it landed somewhere a person can see.
    var frame: NSRect? { panel?.frame }

    func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
        model.items = []
        model.selection = 0
    }

    /// Move the highlight, wrapping — a six-row list is short enough that falling off either end and
    /// stopping reads as the key not working.
    func move(by delta: Int) {
        guard !model.items.isEmpty else { return }
        let count = model.items.count
        model.selection = ((model.selection + delta) % count + count) % count
    }

    private func makePanel(parent: NSWindow) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: MentionList(model: model))
        parent.addChildWindow(panel, ordered: .above)
        self.panel = panel
        return panel
    }
}

/// The rows. Deliberately plain: a mention list is read in the half-second between typing and pressing
/// Return, so it shows the name, the code that names it, and nothing else that has to be read past.
private struct MentionList: View {
    @ObservedObject var model: MentionPopover.Model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.items.prefix(6).enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    if let detail = item.detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let trailing = item.trailing {
                        Text(trailing).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(index == model.selection ? Color.accentColor.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
    }
}
