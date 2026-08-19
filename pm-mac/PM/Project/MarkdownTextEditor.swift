import SwiftUI
import AppKit
import PmLib

/// A plain-text markdown *source* editor with live syntax highlighting, backed by `NSTextView` (the
/// app's floor is macOS 13, below SwiftUI's rich-text `TextEditor`). It edits the raw markdown of a
/// session note — never transforming characters — and only restyles them: headings enlarge, emphasis
/// goes bold/italic, links tint, and the literal markers dim. Native undo (⌘Z) works per-keystroke, and
/// ⌘B / ⌘I / ⌘K wrap the selection. Highlighting logic lives in PmLib (`markdownSpans`, `toggleWrap`,
/// `wrapLink`) so it's unit-tested; this type only maps spans to AppKit attributes.
struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Called on ⌘↩ — the takeover uses it to save and close.
    var onSubmit: (() -> Void)? = nil

    /// Height of the bar this editor runs up underneath, if it has one. Applied as the scroll view's
    /// top content inset, which is what lets the prose scroll *under* the bar while still starting
    /// below it at rest — the same arrangement `safeAreaInset` gives the task list's `ScrollView`.
    /// Zero (the default) is an editor that owns its whole frame.
    var topInset: CGFloat = 0

    /// The editor's base reading face — the system font at a comfortable editing size.
    static let baseFont = NSFont.systemFont(ofSize: 14)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        // No window-derived content insets: this editor's top offset comes from the bar above it and is
        // applied to the text container (see `updateNSView`), so an AppKit-derived one would stack.
        scrollView.automaticallyAdjustsContentInsets = false

        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
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
        textView.font = Self.baseFont
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.string = text
        context.coordinator.highlight(textView)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        (context.coordinator.textView as? ShortcutTextView)?.onSubmit = onSubmit
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
        let wantedInset = NSSize(width: 4, height: 8 + topInset)
        if textView.textContainerInset != wantedInset {
            textView.textContainerInset = wantedInset
            // The scroller still spans the whole height, so start its track below the bar.
            scrollView.scrollerInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
        }
        if textView.string != text {
            textView.string = text
            context.coordinator.highlight(textView)
        }
        // Take focus once, after the view is in a window — this is a focused takeover, so the caret
        // should be ready without a click.
        if !context.coordinator.didFocus {
            context.coordinator.didFocus = true
            afterCurrentUpdate { textView.window?.makeFirstResponder(textView) }
        }

    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor
        weak var textView: NSTextView?
        var didFocus = false

        init(_ parent: MarkdownTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            highlight(textView)
        }

        /// Re-style the whole (short) note: reset to the base attributes, then layer each span's style.
        /// Style-only, on the text storage — it doesn't register undo actions, so native text undo stays
        /// per-keystroke.
        func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let text = textView.string
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: MarkdownTextEditor.baseFont, .foregroundColor: NSColor.labelColor],
                                  range: full)
            for span in markdownSpans(in: text) {
                let ns = NSRange(span.range, in: text)
                storage.addAttributes(markdownAttributes(for: span.kind, base: MarkdownTextEditor.baseFont), range: ns)
            }
            storage.endEditing()
        }
    }
}

/// Maps a markdown span kind to text attributes, sized/faced relative to `base` so the same styling
/// serves the live editor (base = system) and the rendered read view (base = serif). Shared so the
/// editor and the main-view note can't drift apart.
func markdownAttributes(for kind: MarkdownSpanKind, base: NSFont) -> [NSAttributedString.Key: Any] {
    func trait(_ t: NSFontTraitMask) -> NSFont { NSFontManager.shared.convert(base, toHaveTrait: t) }
    switch kind {
    case .heading(let level):
        let bump: CGFloat = level == 1 ? 6 : level == 2 ? 4 : level == 3 ? 2 : 1
        let sized = NSFont(descriptor: base.fontDescriptor, size: base.pointSize + bump) ?? base
        return [.font: NSFontManager.shared.convert(sized, toHaveTrait: .boldFontMask),
                .foregroundColor: NSColor.labelColor]
    case .bold:
        return [.font: trait(.boldFontMask)]
    case .italic:
        return [.font: trait(.italicFontMask)]
    case .code:
        return [.font: NSFont.monospacedSystemFont(ofSize: base.pointSize - 1, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor]
    case .link:
        return [.foregroundColor: NSColor.controlAccentColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue]
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
func renderedMarkdown(_ text: String, base: NSFont, baseColor: NSColor) -> AttributedString {
    let text = reflowHeadingSpacing(text)
    let storage = NSMutableAttributedString(string: text, attributes: [.font: base, .foregroundColor: baseColor])
    let spans = markdownSpans(in: text)
    for span in spans where span.kind != .syntax {
        storage.addAttributes(markdownAttributes(for: span.kind, base: base), range: NSRange(span.range, in: text))
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

/// An `NSTextView` that adds markdown formatting shortcuts (⌘B / ⌘I / ⌘K) with no visible toolbar. Each
/// edits through the normal text-change path (`shouldChangeText`/`didChangeText`), so it's a single,
/// undoable step and the delegate re-highlights afterward.
private final class ShortcutTextView: NSTextView {
    /// Invoked on ⌘↩ to commit and close the editor.
    var onSubmit: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let ch = event.charactersIgnoringModifiers {
            switch ch {
            case "b": apply { toggleWrap($0, selection: $1, marker: "**") }; return true
            case "i": apply { toggleWrap($0, selection: $1, marker: "*") }; return true
            case "k": apply { wrapLink($0, selection: $1) }; return true
            case "\r": onSubmit?(); return true   // ⌘↩ saves and closes
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Run a pure markdown transform over the current text + selection and splice the result back in as
    /// one undoable edit, then restore the returned selection.
    private func apply(_ transform: (String, Range<String.Index>) -> (text: String, selection: Range<String.Index>)) {
        let text = string
        guard let selection = Range(selectedRange(), in: text) else { return }
        let (newText, newSelection) = transform(text, selection)
        let full = NSRange(location: 0, length: (text as NSString).length)
        guard shouldChangeText(in: full, replacementString: newText) else { return }
        textStorage?.replaceCharacters(in: full, with: newText)
        didChangeText()
        setSelectedRange(NSRange(newSelection, in: newText))
    }
}
