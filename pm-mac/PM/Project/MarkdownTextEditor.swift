import SwiftUI
import AppKit
import PmLib

/// A plain-text markdown *source* editor with live syntax highlighting, backed by `NSTextView` (the
/// app's floor is macOS 13, below SwiftUI's rich-text `TextEditor`). It edits the raw markdown of a
/// session note — never transforming characters — and only restyles them: emphasis goes bold/italic,
/// links tint, the literal markers dim and hang out in the margin, and every line sits on one column.
/// Native undo (⌘Z) works per-keystroke.
///
/// Its typographic rule is that **nothing moves while you edit**, formatting included. That is why the
/// face is monospaced and why headings are bold rather than big: in a fixed-advance face a change of
/// weight is a change of colour and nothing more, so wrapping a word in `**` or turning a line into a
/// heading reflows no text and shifts no line. See `baseFont` and `MarkdownGrid`.
///
/// On top of that it does what a markdown editor is expected to do and a bare text view doesn't:
/// Return continues the list or quote you're in (and ends it on an empty item), Tab indents a list item
/// and Shift-Tab outdents it, ⌥↑/⌥↓ move the line, ⌘⇧D duplicates it, typing `*`/`` ` ``/`(` over a
/// selection wraps it instead of replacing it, pasting a URL over a selection makes it a link, dropping
/// or pasting a file writes the link to it, pasting a picture embeds it — saving it beside the note
/// when it has no file of its own — ⌘B / ⌘I / ⌘K format, and ⌘-click follows a link. Prose is
/// spell-checked while every kind of autocorrection stays off.
///
/// All of the text logic lives in PmLib (`markdownSpans`, `continueList`, `indentLines`, `moveLines`,
/// `wrapSelection`, `pasteLink`, `markdownFileLink`, …) so it's unit-tested without a text view; this
/// type maps spans to AppKit attributes and routes keys at the transforms.
struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Called on ⌘↩ — the takeover uses it to save and close.
    var onSubmit: (() -> Void)? = nil

    /// Called on Escape. Nil leaves Escape to the text view, which is what a takeover wants — there the
    /// key is the window's to interpret, and the editor saves on the way out however it leaves. The
    /// quick bar's note surface wants it: Escape there means "out of the writing surface", and nothing
    /// else in a borderless panel is listening for it.
    var onCancel: (() -> Void)? = nil

    /// Reports the height the text actually lays out to, so a host that sizes itself to its content can
    /// follow it. Nil for a host that gives the editor a frame and lets it scroll inside — which is the
    /// takeover, filling a window column that was never the text's to decide.
    ///
    /// The measurement is the used rect plus both container insets: what the scroll view would need to
    /// show the whole note without scrolling. The caller is expected to clamp it — see the quick bar's
    /// `noteMinHeight` and `noteHeightCeiling`, which is where "grows with the prose, then scrolls" is
    /// decided. A host that clamps should hand the same ceiling back as `growthCeiling`.
    var onContentHeight: ((CGFloat) -> Void)? = nil

    /// The tallest the host will grow this editor to before it starts scrolling — the ceiling it
    /// applies to what `onContentHeight` reports. Zero (the default) is a host that gives the editor a
    /// fixed frame, where scrolling is the whole arrangement.
    ///
    /// The editor needs the number for one reason: while the prose still fits under the ceiling, the
    /// host is following it line for line and there is nothing to scroll. AppKit doesn't know that. It
    /// scrolls the caret into view after every insertion, and at the moment it does the frame is still
    /// the height the note was *before* this keystroke — so the last line is out of sight by exactly
    /// the line just typed, and AppKit dutifully scrolls to it. A frame later the host has grown, the
    /// clip view snaps back, and the overlay scroller that flashed on the way has already been seen.
    /// Knowing the ceiling, the editor can simply decline to chase a caret the host is about to reveal.
    var growthCeiling: CGFloat = 0

    /// Bumped to ask for the caret. Any change puts first responder back on the text view.
    ///
    /// It used to be a `didFocus` flag on the coordinator — focus once, on the way in — which is right
    /// for a takeover that is created when it opens and destroyed when it closes. The quick bar's note
    /// surface comes and goes inside a view that stays mounted, and SwiftUI is entitled to keep the
    /// coordinator across that: reopened, the editor found its own flag already set and left the caret
    /// wherever the field it replaced had dropped it, which is nowhere. A value the host owns can't be
    /// stale in that way. Left at its default it focuses exactly once, which is the takeover's case.
    var focusRequest: Int = 0

    /// The face the prose is set in, and the size every markdown style is derived from.
    ///
    /// A parameter rather than the static it used to read directly, because the two hosts want
    /// different faces for the same reason: a takeover fills a window column and is a reading surface,
    /// so it takes the monospaced default; the quick bar's note surface *replaces a text field* set at
    /// 18pt system, and a first line that changes face or size the instant ⇧⏎ turns one into the other
    /// is the seam this is meant not to have. Everything below is relative to whatever it's given —
    /// `markdownAttributes` derives its styles from this face, `MarkdownGrid` measures its gutter in it
    /// — so a proportional host still gets hanging markers and aligned wraps, just without the
    /// no-reflow guarantee that only a fixed-advance face can make.
    var baseFont: NSFont = MarkdownTextEditor.baseFont

    /// Where the text starts, inside the editor's own bounds.
    ///
    /// The width is the whole horizontal offset: the text container's line-fragment padding is zeroed
    /// so this number means what it says, and the default of 9 is the 4 the inset used to be plus the
    /// 5 that padding contributed — the takeover is laid out exactly as it was. The quick bar passes
    /// 0, so the first character of a note sits where the first character of a task did.
    var textInset: NSSize = NSSize(width: 9, height: 8)

    /// Where the note being edited lives on disk, when it's known. Two things need it: a dropped file
    /// is linked relative to it when the two are near each other, and ⌘-click resolves a relative link
    /// against it. Nil just means those fall back to absolute paths.
    var noteURL: URL? = nil

    /// Whether the note opens at its beginning — caret before the first character, scrolled to the top.
    ///
    /// The takeover wants this: you opened the note to read it, and its first line is the one you came
    /// for. The quick bar's note surface must not have it — that surface is a capture line that grew,
    /// and the caret belongs after the words already typed.
    ///
    /// Caret placement is the whole of it, and that's enough: setting a text view's `string` leaves the
    /// caret at the *end* of it, and taking first responder scrolls that caret into view — so a note
    /// opened without this lands at its bottom. With the caret at the start there is nothing to chase,
    /// the note is already showing its first line, and no scrolling correction is needed anywhere.
    var opensAtStart: Bool = false

    /// Height of the bar this editor runs up underneath, if it has one. Applied as the scroll view's
    /// top content inset, which is what lets the prose scroll *under* the bar while still starting
    /// below it at rest — the same arrangement `safeAreaInset` gives the task list's `ScrollView`.
    /// Zero (the default) is an editor that owns its whole frame.
    var topInset: CGFloat = 0

    /// The editor's default reading face — and the reason it's monospaced.
    ///
    /// A note is markdown *source*, and the thing that makes editing source feel cheap is text that
    /// moves while you work on it. In a proportional face it always does: wrapping a word in `**`
    /// re-sets it in bold, bold glyphs are wider than roman ones, and the rest of the paragraph
    /// rewraps around a formatting change that added no words. In a fixed-advance face every weight
    /// and slant shares one advance width, so bolding a word is a change of colour and nothing else —
    /// no reflow, no jitter, the line you were reading stays where it was.
    ///
    /// The same property is what lets the markers *hang* exactly (see `markdownParagraphStyle`): `## `
    /// is three advances wide whatever the heading says, so the gutter is a grid rather than a
    /// measurement that changes per line.
    ///
    /// 13pt because mono reads larger than its point size — the glyphs are wider and the column is
    /// denser — so it sits beside the 13pt task rows without shouting, and matches the rendered read
    /// view exactly, which is what stops a note resizing at the moment you open it to edit.
    static let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// How much taller than its natural leading a line of note prose is set. Mono at its default
    /// leading is a wall; this is the single number that makes it a page.
    ///
    /// Applied as `lineSpacing` — the difference from the natural height, added *below* each line —
    /// rather than as `lineHeightMultiple`, which is the same total and the wrong geometry. A multiple
    /// puts the slack above the glyphs, and AppKit draws the caret over the whole line fragment: the
    /// text sat at the bottom of a 23pt box with a 23pt caret beside it, overhanging by half its own
    /// height again. Below the text the slack costs nothing, because `drawInsertionPoint` can then
    /// simply clamp the caret's height and leave its origin alone.
    /// 1.38 rather than the 1.45 this started at: mono sets a denser column than the proportional face
    /// it replaced, and at 1.45 a note read as more gap than text — a blank line between two paragraphs
    /// became a chasm. Rounded to whole points where it's applied, so every line sits on an integer
    /// grid and no two are a subpixel apart.
    static let lineHeightMultiple: CGFloat = 1.38

    /// The width of the margin every marker hangs into, in character advances.
    ///
    /// Four covers `# ` through `### `, `- `, `> `, and `1. ` through `10. ` — every marker a note
    /// actually uses — so all of them hang clear and every line of content lands on one column. A
    /// longer marker (`#### `, and deeper) clamps at the margin rather than widening it: a gutter that
    /// grew to fit the deepest marker in the document would move the whole note sideways the moment
    /// you typed one, which is the thing this design exists to prevent.
    static let gutterAdvances: CGFloat = 4

    /// This editor's own gutter, in character advances. Defaults to the reading value above.
    ///
    /// A parameter because the two hosts are different rooms. A takeover is a page, where four
    /// characters of margin is where the markers live and the cost is nothing. The quick bar is a
    /// 560pt strip standing in for a one-line field, where four characters of a proportional face is
    /// over 40pt of permanently empty space before the first word — and that field's own text starts
    /// hard against the left edge, so the promotion out of it would step sideways. Two covers `- ` and
    /// `> `, the markers a captured note actually uses.
    var gutterAdvances: CGFloat = MarkdownTextEditor.gutterAdvances

    /// How wide a column of note prose is allowed to get: 78 characters of it, plus the gutter the
    /// markers hang in.
    ///
    /// Measured in characters because that's the thing that actually governs readability, and because
    /// a fixed-advance face makes it exact rather than an estimate. The 700pt cap this replaces for
    /// notes was set for proportional text; at this face it is nearer 90 characters a line, which is
    /// past the width at which the eye reliably finds the start of the next one.
    static let measureWidth: CGFloat = {
        let advance = ("0" as NSString).size(withAttributes: [.font: baseFont]).width
        return (advance * (78 + gutterAdvances)).rounded()
    }()

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = TopPinningScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        // No window-derived content insets: this editor's top offset comes from the bar above it and is
        // applied to the text container (see `updateNSView`), so an AppKit-derived one would stack.
        scrollView.automaticallyAdjustsContentInsets = false

        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        // Folded into `textInset.width` instead, so one number owns where the text starts.
        container.lineFragmentPadding = 0
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)

        let textView = ShortcutTextView(frame: .zero, textContainer: container)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        // A markdown source editor: no smart quotes/dashes/replacements that would corrupt the markup.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // Prose still deserves a spell-check, though: the red underline is advice, and unlike
        // autocorrect it never touches a character of the markup.
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false
        // Dropped files become markdown links rather than nothing at all, and a picture dragged out of
        // a web page — which has no file to link — is written into the note's attachments folder.
        //
        // This *replaces* the set `NSTextView` registers for itself, which is the point: left to its
        // own devices it takes an image drop as a text attachment, and an attachment is not something
        // a plain-markdown file can hold. Every type named here is one this class handles below.
        textView.registerForDraggedTypes([.fileURL] + NoteImagePasteboard.imageTypes)
        textView.font = baseFont
        // The grid an empty note starts on, and what the caret measures itself against before the
        // first highlight pass has anything to style. Without it the first character you type lands
        // flush at the margin and jumps onto the column a keystroke later.
        var grid = MarkdownGrid(base: baseFont, advances: gutterAdvances)
        let empty = grid.style(indent: "", marker: "")
        textView.defaultParagraphStyle = empty
        // …and in the typing attributes, which is the pair that actually governs the caret.
        //
        // An empty note has no characters for the highlight pass to attach a paragraph style to, and
        // `defaultParagraphStyle` alone does not reach `typingAttributes` — so the caret opened at x=0
        // with no head indent and jumped a whole gutter to the right the instant the first character
        // landed and gave the style something to hold on to. Stated here it starts where the text will.
        textView.typingAttributes = [.font: baseFont, .foregroundColor: NSColor.labelColor,
                                     .paragraphStyle: empty]
        textView.textContainerInset = textInset
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.onCancel = onCancel
        textView.noteURL = noteURL
        textView.growthCeiling = growthCeiling
        textView.string = text
        if opensAtStart {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        context.coordinator.highlight(textView)
        scrollView.pinsNextLayout = true
        // After this turn: the text view has no width until it's in the scroll view and laid out, and a
        // height measured before that is the height of text wrapped to nothing.
        afterCurrentUpdate { [weak textView] in
            guard let textView else { return }
            context.coordinator.reportHeight(textView)
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let shortcuts = context.coordinator.textView as? ShortcutTextView {
            shortcuts.onSubmit = onSubmit
            shortcuts.onCancel = onCancel
            shortcuts.noteURL = noteURL
            shortcuts.growthCeiling = growthCeiling
        }
        guard let textView = context.coordinator.textView else { return }

        // Push the text down by insetting the *text container*, not the scroll view.
        //
        // `contentInsets` is the semantically tidier API and it did not work here, twice: it reserves
        // the space without moving the clip view, and every correction for that gets undone by
        // something else on a later turn (taking first responder scrolls the caret into view and works
        // "visible" out without the inset). The text container has no such argument to lose — the
        // document itself simply starts lower, so y = 0 *is* the top, the caret at offset 0 is already
        // in the right place, and there is no negative scroll position for anything to clamp away.
        //
        // `textContainerInset`'s height applies to top and bottom alike, so the note also gains that
        // much room past its last line. In an editor that's welcome rather than a cost: it's the room
        // that lets you scroll the line you're typing up off the bottom edge.
        let wantedInset = NSSize(width: textInset.width, height: textInset.height + topInset)
        if textView.textContainerInset != wantedInset {
            textView.textContainerInset = wantedInset
            // The bar's measured height arriving is the last thing that moves the note before you see
            // it, and it moves it by the height of the bar. Pin, or the first lines open underneath.
            (scrollView as? TopPinningScrollView)?.pinsNextLayout = true
            // The scroller still spans the whole height, so start its track below the bar.
            scrollView.scrollerInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
        }
        if textView.string != text {
            textView.string = text
            if opensAtStart {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            }
            context.coordinator.highlight(textView)
            (scrollView as? TopPinningScrollView)?.pinsNextLayout = true
            // Text put in from outside — a draft restored, or the editor emptied after a note was
            // written — changes the height without a keystroke to notice it.
            afterCurrentUpdate { context.coordinator.reportHeight(textView) }
        }
        // Take focus after the view is in a window: an editor you have to click into is one the host
        // opened for you and then didn't hand over.
        if context.coordinator.focusedRequest != focusRequest {
            context.coordinator.focusedRequest = focusRequest
            context.coordinator.claimFocus(textView)
        }

    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor
        weak var textView: NSTextView?
        /// The last `focusRequest` acted on. Nil until the first update, so a fresh editor focuses.
        var focusedRequest: Int?

        init(_ parent: MarkdownTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            highlight(textView)
            reportHeight(textView)
        }

        /// Take first responder, and check a moment later that it stuck.
        ///
        /// Belt and braces around a handoff this code doesn't control, and the same one the quick bar's
        /// panel does for key status. When this editor replaces a SwiftUI `TextField`, that field's
        /// `@FocusState` is torn down on SwiftUI's own schedule — which can land *after* the responder
        /// change here and put the window back to having no first responder at all. One retry, so a
        /// genuine refusal isn't turned into a loop.
        func claimFocus(_ textView: NSTextView) {
            for delay in Self.focusAttempts {
                // `DispatchQueue.main` rather than `afterCurrentUpdate`, which is the same hop with a
                // `@MainActor` annotation this coordinator isn't in a position to satisfy.
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak textView] in
                    guard let textView, let window = textView.window, !Self.holdsFocus(window, textView)
                    else { return }
                    window.makeFirstResponder(textView)
                }
            }
        }

        /// When to try. Three attempts inside a sixth of a second, and then it gives up rather than
        /// spinning: SwiftUI writes the window's first responder on its own schedule while it tears the
        /// field down, and which of the two writes lands last varies with how the mode was entered —
        /// a summon and a ⇧⏎ promotion produced opposite answers from a single attempt.
        private static let focusAttempts: [TimeInterval] = [0, 0.06, 0.16]

        /// Whether the caret is already in this text view. A focused `NSTextView` may be answered for
        /// by the window's field editor, which is a *different* object delegating to the same place.
        private static func holdsFocus(_ window: NSWindow, _ textView: NSTextView) -> Bool {
            if window.firstResponder === textView { return true }
            guard let editor = window.firstResponder as? NSTextView else { return false }
            return editor.delegate === textView.delegate
        }

        /// Measure the laid-out text and hand the height to whoever asked for it.
        ///
        /// `usedRect` rather than the text view's frame: an `isVerticallyResizable` text view is at
        /// least as tall as its clip view, so its own frame answers "how much room did you give me"
        /// rather than "how much do you need". Layout is forced first — the used rect of a container
        /// that hasn't laid out is whatever it was before the edit.
        func reportHeight(_ textView: NSTextView) {
            guard let report = parent.onContentHeight,
                  let container = textView.textContainer,
                  let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            report(layout.usedRect(for: container).height + textView.textContainerInset.height * 2)
        }

        /// Re-style the whole (short) note in three passes: reset to the base attributes, lay every
        /// line on the paragraph grid, then layer each span's style.
        ///
        /// The grid pass is separate because indent, hang and wrap alignment are *paragraph* properties
        /// — an `NSParagraphStyle` applies to whole paragraphs, so it can't be carried by a span that
        /// covers three words in the middle of one. Setting it per line from `markdownBlocks` is what
        /// makes a wrapped bullet align under its own text instead of falling back to the margin, and
        /// what puts the markers in the gutter.
        ///
        /// Style-only, on the text storage — it doesn't register undo actions, so native text undo stays
        /// per-keystroke.
        func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let text = textView.string
            let base = parent.baseFont
            let full = NSRange(location: 0, length: storage.length)
            var grid = MarkdownGrid(base: base, advances: parent.gutterAdvances)
            storage.beginEditing()
            storage.setAttributes([.font: base,
                                   .foregroundColor: NSColor.labelColor,
                                   .paragraphStyle: grid.style(indent: "", marker: "")],
                                  range: full)
            for block in markdownBlocks(in: text) {
                let style = grid.style(indent: String(text[block.indent]), marker: String(text[block.marker]))
                // `paragraph`, not `range`: the newline belongs to the paragraph it ends, and leaving
                // it on the previous style gives AppKit one paragraph with two styles to lay out.
                storage.addAttribute(.paragraphStyle, value: style, range: NSRange(block.paragraph, in: text))
            }
            for span in markdownSpans(in: text) {
                let ns = NSRange(span.range, in: text)
                storage.addAttributes(markdownAttributes(for: span.kind, base: base), range: ns)
            }
            storage.endEditing()
            // Deleting the last character puts the note back in the state that has nothing to carry the
            // style, so the caret has to be told again. See `makeNSView`.
            if storage.length == 0 {
                textView.typingAttributes = [.font: base, .foregroundColor: NSColor.labelColor,
                                             .paragraphStyle: grid.style(indent: "", marker: "")]
            }
        }
    }
}

/// A scroll view that keeps its document at the top whenever the whole of it fits.
///
/// The clip view's origin outlives the reason it was moved. A note that scrolled — because it was past
/// the host's ceiling, or because the caret was chased before the host grew — and is then cut back down
/// to something that fits leaves the offset behind, so the first lines sit above the top edge with
/// blank space under the last. Re-checking on layout costs nothing and is a no-op for a note that
/// really is taller than its frame, which is the takeover's usual state.
private final class TopPinningScrollView: NSScrollView {
    /// Set when a document is put in from outside, to pin the *next* layout to the top whether or not
    /// the note fits.
    ///
    /// The fits-in-view rule below can't cover this on its own, and used to look like it did only
    /// because notes were shorter: a note opened into a takeover is taller than the pane more often
    /// than not, so "it fits" is the exceptional case rather than the normal one. A freshly loaded
    /// document starts at its own top — the first line of the note is the one you opened it to read,
    /// and finding it already scrolled under the header bar is the whole of the bug this fixes.
    var pinsNextLayout = false

    override func layout() {
        super.layout()
        // How far down the document we are — *not* `contentView.bounds.origin.y`, which is a different
        // question with a different answer.
        //
        // A clip view showing the top of a document taller than itself does not sit at bounds origin
        // zero: the document view's own frame origin goes negative and the clip's bounds origin matches
        // it, and it's the two being equal that means "at the top". Scrolling the bounds to zero breaks
        // that pairing and moves the note *down* by the whole of the document's negative origin, which
        // is how a pin-to-top ended up hiding the first lines behind the header bar. `documentVisibleRect`
        // is stated in document coordinates and so answers the question directly, whatever convention
        // the two frames happen to be using underneath.
        let offset = documentVisibleRect.minY
        guard let document = documentView, offset != 0 else {
            pinsNextLayout = false
            return
        }
        guard pinsNextLayout || document.frame.height <= contentView.bounds.height + 0.5 else { return }
        pinsNextLayout = false
        contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x,
                                       y: contentView.bounds.origin.y - offset))
        reflectScrolledClipView(contentView)
    }
}

/// Resolve a markdown link's destination to something openable: an `http:`-style URL as it's written,
/// and anything else as a file, looked for the way `resolveNoteReference` looks — beside the note
/// first, then where the vault keeps its attachments.
///
/// The search is what makes a note written elsewhere readable here. A link relative to the note is
/// PM's own form and resolves on the first try; a path relative to the *vault root* is Obsidian's, and
/// from a note several folders down it means nothing until someone looks up.
///
/// A destination that points at nothing comes back nil, and callers rely on that: it isn't a link, so
/// the read view leaves it as plain text and a ⌘-click in the editor places the caret instead of
/// handing the Finder a file it can't open.
func markdownDestinationURL(_ destination: String, relativeTo note: URL?) -> URL? {
    let raw = destination.trimmingCharacters(in: .whitespaces)
    guard !raw.isEmpty else { return nil }
    if let url = URL(string: raw), url.scheme != nil, !url.isFileURL { return url }
    return resolveNoteReference(raw, noteAt: note)
}

/// Maps a markdown span kind to text attributes, sized/faced relative to `base` so the same styling
/// serves the live editor (base = system) and the rendered read view (base = serif). Shared so the
/// editor and the main-view note can't drift apart.
func markdownAttributes(for kind: MarkdownSpanKind, base: NSFont,
                        scaleHeadings: Bool = false) -> [NSAttributedString.Key: Any] {
    func trait(_ t: NSFontTraitMask) -> NSFont { NSFontManager.shared.convert(base, toHaveTrait: t) }
    switch kind {
    case .heading(let level):
        // In the editor (`scaleHeadings: false`): bold, at body size, at every level. Hierarchy comes
        // from weight, from the space the note's own blank lines already put above a heading, and from
        // the hashes hanging in the gutter — not from size, which is the one axis that can't change
        // without moving the rest of the document. A heading that grew would push everything below it
        // down the instant you typed the `#`, and would take its own text off the column every other
        // line is set on.
        //
        // In the rendered read view: sized. Not an inconsistency but the consequence of one — that view
        // *deletes* the markers, so the hashes that carry the level in the editor aren't there to read,
        // and without size an H1 and an H3 are the same bold line. Nothing is typed into a rendered
        // view, so the rule the editor is keeping doesn't apply to it; the body text, which is what
        // actually resized under you before, is now identical across the two.
        guard scaleHeadings else {
            return [.font: trait(.boldFontMask), .foregroundColor: NSColor.labelColor]
        }
        let bump: CGFloat = level == 1 ? 5 : level == 2 ? 3 : level == 3 ? 1 : 0
        let sized = NSFont(descriptor: base.fontDescriptor, size: base.pointSize + bump) ?? base
        return [.font: NSFontManager.shared.convert(sized, toHaveTrait: .boldFontMask),
                .foregroundColor: NSColor.labelColor]
    case .bold:
        return [.font: trait(.boldFontMask)]
    case .italic:
        return [.font: trait(.italicFontMask)]
    case .code:
        // Same face and size as the prose around it — in a monospaced note there is no mono face left
        // to switch *to*, and a size change here would break the grid for the sake of a distinction a
        // tint already makes. The background is what says "code"; it costs no width.
        return [.font: NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular),
                .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12)]
    case .link:
        return [.foregroundColor: NSColor.controlAccentColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue]
    case .wikilink:
        // A vault reference reads as a link, without the underline: the target is a note in the same
        // folder, not a place off in a browser.
        return [.foregroundColor: NSColor.controlAccentColor]
    case .listMarker:
        return [.foregroundColor: NSColor.secondaryLabelColor]
    case .blockquote:
        return [.foregroundColor: NSColor.secondaryLabelColor, .font: trait(.italicFontMask)]
    case .strikethrough:
        return [.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.secondaryLabelColor]
    case .syntax:
        return [.foregroundColor: NSColor.tertiaryLabelColor]
    }
}

/// Lays every line of a note on one column, with its marker hanging in the margin beside it.
///
/// Given a content column `G` (the gutter), a line renders as `[indent][marker][content]`, and the two
/// indents that put it where it belongs are:
///
///   firstLineHeadIndent = G - width(marker)    → the marker starts left of the column, content on it
///   headIndent          = G + width(indent)    → wrapped lines align under the content, not the marker
///
/// The marker's own width is the only thing the hang depends on, which is why `MarkdownBlock` keeps
/// the indent and the marker apart: `- ` is two advances at every nesting depth, so a nested item's
/// bullet hangs exactly as far as a top-level one's and only the column steps right — by precisely the
/// whitespace that was typed, whether the note nests by two spaces, four, or tabs.
///
/// A value type with a cache because a note's prefixes repeat: a list is fifteen lines of `- ` and the
/// prose between them is fifteen lines of nothing, so measuring is a handful of calls per pass rather
/// than two per line. Widths are measured rather than counted in advances so the same grid serves the
/// quick bar's proportional face, where a marker's width is not its character count.
private struct MarkdownGrid {
    let base: NSFont
    let gutter: CGFloat
    /// The gap under each line — see `MarkdownTextEditor.lineHeightMultiple` for why it goes below.
    let leading: CGFloat
    private var widths: [String: CGFloat] = [:]
    private var styles: [String: NSParagraphStyle] = [:]

    init(base: NSFont, advances: CGFloat) {
        self.base = base
        self.gutter = ("0" as NSString).size(withAttributes: [.font: base]).width * advances
        self.leading = (NSLayoutManager().defaultLineHeight(for: base)
            * (MarkdownTextEditor.lineHeightMultiple - 1)).rounded()
    }

    mutating func style(indent: String, marker: String) -> NSParagraphStyle {
        let key = "\(indent)\u{0}\(marker)"
        if let hit = styles[key] { return hit }
        let column = gutter + width(indent)
        let style = NSMutableParagraphStyle()
        // Clamped at the margin: a marker wider than the gutter (`#### ` and deeper) starts flush left
        // and pushes its own content a little right, rather than widening the gutter for the whole
        // note. See `gutterAdvances`.
        style.firstLineHeadIndent = max(0, gutter - width(marker))
        style.headIndent = column
        style.lineSpacing = leading
        // No synthetic spacing above a heading or between paragraphs. This is a *source* editor: the
        // blank lines that separate blocks are real lines, visible and editable, and adding space on
        // top of them would both double-count and make typing a `#` shove the rest of the note down.
        styles[key] = style
        return style
    }

    private mutating func width(_ s: String) -> CGFloat {
        if s.isEmpty { return 0 }
        if let hit = widths[s] { return hit }
        let w = (s as NSString).size(withAttributes: [.font: base]).width
        widths[s] = w
        return w
    }
}

/// Regroup heading spacing for the rendered read view so a heading belongs to the content it introduces:
/// drop the blank line(s) right after a heading (hug the following content) and guarantee one blank line
/// before it (separate it from the previous content). Text-level, so it's independent of whether the
/// renderer honors paragraph spacing.
private func reflowHeadingSpacing(_ text: String) -> String {
    func isHeading(_ line: String) -> Bool {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes >= 1, hashes <= 6 else { return false }
        let after = line.dropFirst(hashes)
        return after.isEmpty || after.first == " " || after.first == "\t"
    }
    var out: [String] = []
    var hugging = false   // just emitted a heading — swallow blank lines until its content starts
    for line in text.components(separatedBy: "\n") {
        let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
        if hugging && blank { continue }
        hugging = false
        if isHeading(line) {
            if let last = out.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { out.append("") }
            out.append(line)
            hugging = true
        } else {
            out.append(line)
        }
    }
    return out.joined(separator: "\n")
}

/// A rendered (read-only) attributed version of markdown for the main-view note: inline emphasis, code,
/// links, and heading sizes applied, list/quote content styled, and the literal markers (`**`, `#`,
/// backticks, link brackets/URL) removed for a clean look. Uses the same `markdownAttributes` as the
/// editor so the two stay consistent.
///
/// Links are real links here, not just tinted text — this is the read view, so a click should follow
/// the link rather than land a caret in it (which is the editor's job, and why ⌘ is required there).
/// `note` is the file the markdown came from, so a relative destination resolves to the vault it names.
func renderedMarkdown(_ text: String, base: NSFont, baseColor: NSColor, note: URL? = nil) -> AttributedString {
    let text = reflowHeadingSpacing(text)
    let storage = NSMutableAttributedString(string: text, attributes: [.font: base, .foregroundColor: baseColor])
    let spans = markdownSpans(in: text)
    for span in spans where span.kind != .syntax {
        storage.addAttributes(markdownAttributes(for: span.kind, base: base, scaleHeadings: true),
                              range: NSRange(span.range, in: text))
    }
    for link in markdownLinks(in: text) {
        guard let url = markdownDestinationURL(link.destination, relativeTo: note) else { continue }
        storage.addAttribute(.link, value: url, range: NSRange(link.labelRange, in: text))
    }
    // Delete markers from the end so earlier ranges keep their indices.
    let syntax = spans.filter { $0.kind == .syntax }
        .map { NSRange($0.range, in: text) }
        .sorted { $0.location > $1.location }
    for r in syntax where r.location + r.length <= storage.length {
        storage.deleteCharacters(in: r)
    }
    return AttributedString(storage)
}

/// An `NSTextView` that adds the editing behaviours a markdown editor is expected to have, with no
/// visible toolbar: Return continues a list, Tab indents one, ⌥↑/⌥↓ move a line, ⌘⇧D duplicates it,
/// ⌘B / ⌘I / ⌘K format the selection, typing a marker over a selection wraps it, a pasted URL becomes a
/// link, a dropped or pasted file becomes a link to itself, a pasted picture becomes an embed, and
/// ⌘-click follows a link.
///
/// Every one of them edits through the normal text-change path (`shouldChangeText`/`didChangeText`), so
/// it's a single undoable step and the delegate re-highlights afterward, and every one of them is a
/// pure PmLib transform over (text, selection) — this class decides *when*, never *what*.
private final class ShortcutTextView: NSTextView {
    /// Invoked on ⌘↩ to commit and close the editor.
    var onSubmit: (() -> Void)?
    /// Invoked on Escape, when the host has something for it to mean. See `MarkdownTextEditor.onCancel`.
    var onCancel: (() -> Void)?
    /// The note's own location on disk, for resolving dropped files and relative links.
    var noteURL: URL?
    /// See `MarkdownTextEditor.growthCeiling`. Zero means the host isn't growing, so the caret is this
    /// view's own to chase.
    var growthCeiling: CGFloat = 0

    /// Draw the caret at the height of the text, not of the line box.
    ///
    /// AppKit hands `drawInsertionPoint` the whole line fragment, and a note's fragment is the glyph
    /// box plus the gap to the next line — 23pt of box around 15pt of text. Left alone the caret is
    /// the taller of the two and reads as sitting off the line it's on.
    ///
    /// Clamping the height is enough, and moving it would be wrong: the leading is applied as
    /// `lineSpacing`, so the slack is *below* the text and the top of the fragment is already the top
    /// of the glyphs. Shrinking rather than growing also means AppKit's own invalidation rect still
    /// covers everything drawn, so there's no trail to clean up behind a blinking caret.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var caret = rect
        caret.size.height = min(rect.height, caretHeight)
        super.drawInsertionPoint(in: caret, color: color, turnedOn: flag)
    }

    /// Ascender to descender of the face at the caret — the text's own height, rounded up so the caret
    /// never stops a fraction short of a glyph.
    private var caretHeight: CGFloat {
        let face = (typingAttributes[.font] as? NSFont) ?? font ?? MarkdownTextEditor.baseFont
        return (face.ascender - face.descender).rounded(.up)
    }

    /// Don't chase the caret while the host is still growing to show it.
    ///
    /// AppKit scrolls the insertion point into view after an edit, and under a host that sizes itself
    /// to the prose that scroll is always one keystroke early: the frame it measures against is the one
    /// from before the line was typed. The result is a clip view that jumps down and snaps back on the
    /// next frame, flashing an overlay scroller each time. Past the ceiling the host has stopped
    /// growing, the note genuinely scrolls, and this gets out of the way.
    override func scrollRangeToVisible(_ range: NSRange) {
        guard growthCeiling <= 0 || laidOutHeight() > growthCeiling else { return }
        super.scrollRangeToVisible(range)
    }



    /// What the whole note needs to show without scrolling. The same measurement
    /// `MarkdownTextEditor.Coordinator.reportHeight` hands the host, so the two agree about the ceiling.
    private func laidOutHeight() -> CGFloat {
        guard let container = textContainer, let layout = layoutManager else { return 0 }
        layout.ensureLayout(for: container)
        return layout.usedRect(for: container).height + textContainerInset.height * 2
    }

    // MARK: keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let ch = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        if flags == .command {
            switch ch {
            case "b": apply { toggleWrap($0, selection: $1, marker: "**") }; return true
            case "i": apply { toggleWrap($0, selection: $1, marker: "*") }; return true
            case "k": apply { wrapLink($0, selection: $1) }; return true
            case "\r": onSubmit?(); return true   // ⌘↩ saves and closes
            default: break
            }
        }
        if flags == [.command, .shift], ch == "d" {
            apply { duplicateLines($0, selection: $1) }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Escape. Handed to the host when it wants it, and otherwise left to the text view — where it
    /// dismisses an open completion list, which is a use worth not stealing.
    override func cancelOperation(_ sender: Any?) {
        guard let onCancel else {
            super.cancelOperation(sender)
            return
        }
        onCancel()
    }

    override func keyDown(with event: NSEvent) {
        // ⌥↑ / ⌥↓ move the line, the binding every editor that has the feature uses. It costs the
        // system's option-arrow paragraph navigation, which in a note this size is the cheaper of the
        // two: the lines being reordered are bullets, and there are no paragraphs to jump between.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option,
           event.keyCode == 126 || event.keyCode == 125 {
            let up = event.keyCode == 126
            // Nothing to swap with at the ends of the note — stay put rather than beep.
            applyIfPossible { moveLines($0, selection: $1, up: up) }
            return
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            if applyIfPossible({ continueList($0, selection: $1) }) { return }
        case #selector(insertTab(_:)):
            if indentIfInList(outdent: false) { return }
            // Prose gets Tab's other meaning. A literal tab in a note is invisible at best and a code
            // block at worst, and moving on to the Back button is what Tab means in a panel.
            window?.selectNextKeyView(nil)
            return
        case #selector(insertBacktab(_:)):
            if indentIfInList(outdent: true) { return }
            window?.selectPreviousKeyView(nil)
            return
        default:
            break
        }
        super.doCommand(by: selector)
    }

    /// Indent or outdent, when the selection is somewhere Tab should mean that.
    private func indentIfInList(outdent: Bool) -> Bool {
        let text = string
        guard let selection = Range(selectedRange(), in: text),
              tabShouldIndent(text, selection: selection) else { return false }
        apply { outdent ? outdentLines($0, selection: $1) : indentLines($0, selection: $1) }
        return true
    }

    // MARK: typing and pasting

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        // A marker typed over a selection wraps it — `*` italicises the words rather than deleting
        // them. Not while composing with an input method, where the text isn't committed yet.
        if !hasMarkedText(), selectedRange().length > 0, typed.count == 1,
           let character = typed.first, let pair = markdownWrapPair(for: character) {
            apply { wrapSelection($0, selection: $1, open: pair.open, close: pair.close) }
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        // A URL pasted over a selection links the selection.
        if selectedRange().length > 0,
           let pasted = pasteboard.string(forType: .string), isPastableURL(pasted) {
            apply { pasteLink($0, selection: $1, url: pasted) }
            return
        }
        // A picture pasted into a note becomes a picture *in* the note, by the same two rules a drop
        // uses: an image file is linked where it already lives, and an image with no file — a
        // screenshot, a copy out of a browser — is written into the note's attachments folder first,
        // because otherwise there's nothing for the link to point at. Anything else pastes as itself.
        if let files = NoteImagePasteboard.imageFiles(on: pasteboard) {
            insert(fileLinks(for: files), at: selectedRange())
            return
        }
        if let image = NoteImagePasteboard.imageData(on: pasteboard),
           let embed = savedImageEmbed(image) {
            insert(embed, at: selectedRange())
            return
        }
        super.paste(sender)
    }

    // MARK: writing images into the note

    /// Write a pasted image beside the note and return the embed for where it landed, or nil when
    /// there's nowhere to put it — the quick bar's note isn't a file yet, and a note that can't say
    /// where it lives can't hold a relative link to anything.
    ///
    /// A failed write falls through to the normal paste rather than beeping: the picture is still on
    /// the pasteboard, and text in the note beats nothing in the note.
    private func savedImageEmbed(_ image: (data: Data, ext: String)) -> String? {
        guard let noteURL else { return nil }
        do {
            let file = try saveNoteAttachment(image.data, ext: image.ext, forNoteAt: noteURL)
            return markdownImageEmbed(for: file, relativeTo: noteURL, alt: "Pasted image")
        } catch {
            Log.write("note attachment write failed: \(error)")
            return nil
        }
    }

    /// The markdown for a set of files, one per line.
    private func fileLinks(for files: [URL]) -> String {
        files.map { markdownFileLink(for: $0, relativeTo: noteURL) }.joined(separator: "\n")
    }

    /// Splice `snippet` in over `target` as one undoable edit, leaving the caret after it.
    @discardableResult
    private func insert(_ snippet: String, at target: NSRange) -> Bool {
        guard shouldChangeText(in: target, replacementString: snippet) else { return false }
        textStorage?.replaceCharacters(in: target, with: snippet)
        didChangeText()
        setSelectedRange(NSRange(location: target.location + (snippet as NSString).length, length: 0))
        return true
    }

    // MARK: dropped files

    private func droppedFiles(_ sender: NSDraggingInfo) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return (urls?.isEmpty ?? true) ? nil : urls
    }

    /// A dragged image that isn't a file — one dragged straight out of a web page — which the note
    /// writes down for itself, exactly as it does for a pasted one.
    private func draggedImage(_ sender: NSDraggingInfo) -> (data: Data, ext: String)? {
        guard noteURL != nil else { return nil }
        return NoteImagePasteboard.imageData(on: sender.draggingPasteboard)
    }

    private func acceptsDrag(_ sender: NSDraggingInfo) -> Bool {
        droppedFiles(sender) != nil || draggedImage(sender) != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsDrag(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsDrag(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let snippet: String
        if let files = droppedFiles(sender) {
            snippet = fileLinks(for: files)
        } else if let image = draggedImage(sender), let embed = savedImageEmbed(image) {
            snippet = embed
        } else {
            return super.performDragOperation(sender)
        }
        // Land it where it was dropped, not where the caret happened to be.
        let at = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        guard insert(snippet, at: NSRange(location: at, length: 0)) else { return false }
        window?.makeFirstResponder(self)
        return true
    }

    // MARK: following links

    override func mouseDown(with event: NSEvent) {
        // ⌘-click follows a link. A plain click stays a plain click: this is a source editor, and the
        // caret has to be able to land inside `[label](url)` to edit it.
        if event.modifierFlags.contains(.command), let url = link(under: event) {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
    }

    /// The link the pointer is over, anywhere in its `[label](url)`, resolved against the note.
    private func link(under event: NSEvent) -> URL? {
        let text = string
        let offset = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        guard offset <= (text as NSString).length else { return nil }
        let index = String.Index(utf16Offset: offset, in: text)
        for link in markdownLinks(in: text) where link.range.contains(index) {
            return markdownDestinationURL(link.destination, relativeTo: noteURL)
        }
        return nil
    }

    // MARK: applying transforms

    /// Run a pure markdown transform over the current text + selection and splice the result back in as
    /// one undoable edit, then restore the returned selection.
    private func apply(_ transform: (String, Range<String.Index>) -> (text: String, selection: Range<String.Index>)) {
        _ = applyIfPossible { transform($0, $1) }
    }

    /// The same, for a transform that only sometimes applies. Returns whether it did, so the caller can
    /// fall through to the text view's own behaviour when it didn't.
    @discardableResult
    private func applyIfPossible(_ transform: (String, Range<String.Index>) -> (text: String, selection: Range<String.Index>)?) -> Bool {
        let text = string
        guard let selection = Range(selectedRange(), in: text),
              let (newText, newSelection) = transform(text, selection) else { return false }
        // Close whatever typing was still being coalesced first. These edits rewrite the whole note in
        // one go, and without the break AppKit folds them into the run of keystrokes before them —
        // one ⌘Z then takes the sentence you typed along with the list marker you asked it to undo.
        breakUndoCoalescing()
        let full = NSRange(location: 0, length: (text as NSString).length)
        guard shouldChangeText(in: full, replacementString: newText) else { return false }
        textStorage?.replaceCharacters(in: full, with: newText)
        didChangeText()
        setSelectedRange(NSRange(newSelection, in: newText))
        scrollRangeToVisible(selectedRange())
        breakUndoCoalescing()
        return true
    }
}
