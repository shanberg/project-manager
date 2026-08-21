import SwiftUI
import AppKit
import PmLib

/// A plain-text markdown *source* editor with live syntax highlighting, backed by `NSTextView` (the
/// app's floor is macOS 13, below SwiftUI's rich-text `TextEditor`). It edits the raw markdown of a
/// session note — never transforming characters — and only restyles them: headings enlarge, emphasis
/// goes bold/italic, links tint, and the literal markers dim. Native undo (⌘Z) works per-keystroke.
///
/// On top of that it does what a markdown editor is expected to do and a bare text view doesn't:
/// Return continues the list or quote you're in (and ends it on an empty item), Tab indents a list item
/// and Shift-Tab outdents it, ⌥↑/⌥↓ move the line, ⌘⇧D duplicates it, typing `*`/`` ` ``/`(` over a
/// selection wraps it instead of replacing it, pasting a URL over a selection makes it a link, dropping
/// a file writes the link to it, ⌘B / ⌘I / ⌘K format, and ⌘-click follows a link. Prose is spell-checked
/// while every kind of autocorrection stays off.
///
/// All of the text logic lives in PmLib (`markdownSpans`, `continueList`, `indentLines`, `moveLines`,
/// `wrapSelection`, `pasteLink`, `markdownFileLink`, …) so it's unit-tested without a text view; this
/// type maps spans to AppKit attributes and routes keys at the transforms.
struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Called on ⌘↩ — the takeover uses it to save and close.
    var onSubmit: (() -> Void)? = nil

    /// Where the note being edited lives on disk, when it's known. Two things need it: a dropped file
    /// is linked relative to it when the two are near each other, and ⌘-click resolves a relative link
    /// against it. Nil just means those fall back to absolute paths.
    var noteURL: URL? = nil

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
        // Prose still deserves a spell-check, though: the red underline is advice, and unlike
        // autocorrect it never touches a character of the markup.
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false
        // Dropped files become markdown links rather than nothing at all.
        textView.registerForDraggedTypes([.fileURL])
        textView.font = Self.baseFont
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.noteURL = noteURL
        textView.string = text
        context.coordinator.highlight(textView)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let shortcuts = context.coordinator.textView as? ShortcutTextView {
            shortcuts.onSubmit = onSubmit
            shortcuts.noteURL = noteURL
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

/// Resolve a markdown link's destination to something openable: an absolute URL as it's written, and a
/// relative path against the folder the note itself lives in — which is how a link to another note or
/// an attachment in the same vault is written, and the only way it can be resolved.
func markdownDestinationURL(_ destination: String, relativeTo note: URL?) -> URL? {
    let raw = destination.trimmingCharacters(in: .whitespaces)
    guard !raw.isEmpty else { return nil }
    if let url = URL(string: raw), url.scheme != nil, !url.isFileURL { return url }
    let path = NSString(string: raw.removingPercentEncoding ?? raw).expandingTildeInPath
    let file: URL
    if path.hasPrefix("/") {
        file = URL(fileURLWithPath: path)
    } else if let note {
        file = URL(fileURLWithPath: path, relativeTo: note.deletingLastPathComponent()).standardizedFileURL
    } else {
        return nil
    }
    // A path that points at nothing isn't a link: leave it as plain text in the read view, and let a
    // ⌘-click in the editor place the caret instead of handing the Finder a file it can't open.
    return FileManager.default.fileExists(atPath: file.path) ? file : nil
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
        storage.addAttributes(markdownAttributes(for: span.kind, base: base), range: NSRange(span.range, in: text))
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
/// link, a dropped file becomes a link to itself, and ⌘-click follows a link.
///
/// Every one of them edits through the normal text-change path (`shouldChangeText`/`didChangeText`), so
/// it's a single undoable step and the delegate re-highlights afterward, and every one of them is a
/// pure PmLib transform over (text, selection) — this class decides *when*, never *what*.
private final class ShortcutTextView: NSTextView {
    /// Invoked on ⌘↩ to commit and close the editor.
    var onSubmit: (() -> Void)?
    /// The note's own location on disk, for resolving dropped files and relative links.
    var noteURL: URL?

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
        // A URL pasted over a selection links the selection. Anything else pastes as itself.
        if selectedRange().length > 0,
           let pasted = NSPasteboard.general.string(forType: .string), isPastableURL(pasted) {
            apply { pasteLink($0, selection: $1, url: pasted) }
            return
        }
        super.paste(sender)
    }

    // MARK: dropped files

    private func droppedFiles(_ sender: NSDraggingInfo) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return (urls?.isEmpty ?? true) ? nil : urls
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender) != nil ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender) != nil ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let files = droppedFiles(sender) else { return super.performDragOperation(sender) }
        let snippet = files.map { markdownFileLink(for: $0, relativeTo: noteURL) }.joined(separator: "\n")
        // Land it where it was dropped, not where the caret happened to be.
        let at = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        let target = NSRange(location: at, length: 0)
        guard shouldChangeText(in: target, replacementString: snippet) else { return false }
        textStorage?.replaceCharacters(in: target, with: snippet)
        didChangeText()
        setSelectedRange(NSRange(location: at + (snippet as NSString).length, length: 0))
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
