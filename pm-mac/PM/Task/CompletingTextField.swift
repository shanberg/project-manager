import AppKit
import SwiftUI
import PmLib

/// An `NSTextField` that offers a click to its owner before the field editor takes it.
///
/// A click inside a field that's already editing goes straight to the field editor, so a token can't
/// intercept it from the delegate. This is the one place that can.
final class TokenClickField: NSTextField {
    var onTokenClick: ((NSPoint) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        if onTokenClick?(event.locationInWindow) == true { return }
        super.mouseDown(with: event)
    }
}

/// A one-line text field with the same `@` / `/` completion the note editor has.
///
/// It exists because the note editor is not where most tasks are written. Add Task, Edit Task and Wrap
/// are the inline editors in the task list, and they were plain `TextField`s — so typing `@ven` into
/// the place you actually add a task produced a task literally called "@ven". The loop has to be
/// wherever a task line is typed, not only where the file is.
///
/// An `NSViewRepresentable` over `NSTextField` rather than a SwiftUI `TextField`, for the same reason
/// the popover is a panel: the list needs the arrow keys and Return *before* the field does, and
/// SwiftUI gives no way to sit in front of a `TextField`'s key handling.
struct CompletingTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    /// Return, when the completion list isn't up to claim it.
    let onSubmit: () -> Void
    /// Escape, likewise.
    let onCancel: () -> Void
    /// Open the project a token names, by folder name. Supplied by the surface that owns navigation.
    var onOpenProject: ((String) -> Void)?
    /// Focus this field once it's in the responder chain.
    var focusOnAppear = true

    func makeNSView(context: Context) -> NSTextField {
        let field = TokenClickField(string: text)
        field.onTokenClick = { [weak coordinator = context.coordinator] point in
            coordinator?.openTokenIfClicked(at: point) ?? false
        }
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.controlSize = .small
        field.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        context.coordinator.field = field
        DispatchQueue.main.async { context.coordinator.restyleFromField() }
        if focusOnAppear {
            // Next runloop turn, for the reason `AddEditor` spells out: focus requested from inside the
            // update that inserts the field has nothing to land on yet.
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Only when they actually differ: assigning `stringValue` resets the caret to the end, which
        // mid-word is the field editing you.
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CompletingTextField
        weak var field: NSTextField?
        let completions = CompletionController()
        /// A field editor's layout manager belongs to the window, so this can only be its *delegate* —
        /// which carries the glyph half of `TokenLayoutManager` (brackets become the pill's padding)
        /// but not the drawing half, since `drawBackground` is an override rather than a delegate
        /// method. The field therefore shows a token's spacing without its fill. Installed while this
        /// field is the one being edited and taken off again when it isn't; leaving it on would reshape
        /// whatever got edited next.
        let glyphHider = TokenLayoutManager()

        init(_ parent: CompletingTextField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            editor?.layoutManager?.delegate = glyphHider
            restyle()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field else { return }
            parent.text = field.stringValue
            restyle()
            refresh()
        }

        /// Draw the `[[…]]` spans as tokens rather than as markup.
        ///
        /// The same wash and accent the note editor gives them, for the same reason: the token
        /// *behaves* as one thing — the caret steps over it, backspace takes all of it — and a control
        /// that behaves atomically while looking like plain text is a control whose keys feel broken.
        /// The brackets are dimmed rather than hidden, so what's on screen is still what's in the file.
        ///
        /// Reapplied on every change because a field editor is shared and resets its attributes as it
        /// goes; there is no styled-storage to install once.
        private func restyle() {
            guard let editor, let storage = editor.textStorage else { return }
            let text = editor.string
            let whole = NSRange(location: 0, length: (text as NSString).length)
            storage.removeAttribute(.backgroundColor, range: whole)
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: whole)
            for span in wikilinkSpans(in: text) {
                let range = NSRange(span, in: text)
                storage.addAttributes([.foregroundColor: NSColor.controlAccentColor,
                                       .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.10)],
                                      range: range)
                // The markers, quieter than the name they carry.
                for marker in [NSRange(location: range.location, length: min(2, range.length)),
                               NSRange(location: max(range.location, range.upperBound - 2), length: 2)]
                where marker.upperBound <= whole.upperBound {
                    storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: marker)
                }
            }
        }

        /// The field editor is the `NSTextView` doing the actual editing; the caret and the glyph rects
        /// both live on it rather than on the field.
        private var editor: NSTextView? { field?.currentEditor() as? NSTextView }

        private func refresh() {
            guard let field, let editor else { return }
            let text = field.stringValue
            guard editor.selectedRange().length == 0,
                  let caret = Range(editor.selectedRange(), in: text)?.lowerBound else {
                return completions.dismissAll()
            }
            completions.refresh(text: text, caret: caret, screenAnchor: { range in
                editor.firstRect(forCharacterRange: NSRange(range, in: text), actualRange: nil)
            }, in: field)
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            let text = textView.string
            guard let caret = Range(textView.selectedRange(), in: text)?.lowerBound else { return false }
            // The list gets first refusal on its keys. Everything else — including Return and Escape
            // when no list is up — falls through to the field's own meaning.
            let keyCode: UInt16?
            switch selector {
            case #selector(NSResponder.moveUp(_:)): keyCode = 126
            case #selector(NSResponder.moveDown(_:)): keyCode = 125
            case #selector(NSResponder.insertNewline(_:)): keyCode = 36
            case #selector(NSResponder.insertTab(_:)): keyCode = 48
            case #selector(NSResponder.cancelOperation(_:)): keyCode = 53
            default: keyCode = nil
            }
            // A token is one thing here too: the caret steps over it and backspace takes all of it.
            // Same PmLib transforms the note editor uses, so the two surfaces can't drift.
            switch selector {
            case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)):
                let forward = selector == #selector(NSResponder.moveRight(_:))
                if textView.selectedRange().length == 0,
                   let stepped = stepCaret(in: text, from: caret, forward: forward),
                   abs(text.distance(from: caret, to: stepped)) > 1 {
                    textView.setSelectedRange(NSRange(stepped..<stepped, in: text))
                    refresh()
                    return true
                }
            case #selector(NSResponder.deleteBackward(_:)):
                if textView.selectedRange().length == 0,
                   let out = deleteWikilinkBefore(text, index: caret) {
                    textView.string = out.text
                    textView.setSelectedRange(NSRange(out.selection, in: out.text))
                    parent.text = out.text
                    restyle()
                    refresh()
                    return true
                }
            default:
                break
            }
            if let keyCode {
                switch completions.handle(keyCode: keyCode, text: text, caret: caret) {
                case .handled:
                    return true
                case .apply(let newText, let selection):
                    textView.string = newText
                    textView.setSelectedRange(NSRange(selection, in: newText))
                    parent.text = newText
                    restyle()
                    // Ask again: a `/waiting` has just written the sigil the picker should open on.
                    refresh()
                    return true
                case .ignored:
                    break
                }
            }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }

        /// Arrow keys and clicks move the caret without changing the text, and the list has to follow —
        /// otherwise it keeps offering matches for a sigil the caret has already left.
        /// Style a value that arrived without being typed — an Edit Task seeded with a line that
        /// already carries a wait.
        func restyleFromField() { restyle() }

        func controlTextDidEndEditing(_ notification: Notification) {
            if editor?.layoutManager?.delegate === glyphHider {
                editor?.layoutManager?.delegate = nil
            }
            completions.dismissAll()
        }

        /// A click on a token opens what it names.
        ///
        /// A plain click, not ⌘-click. The editor requires ⌘ to follow a markdown link because the
        /// caret has to be able to land inside `[label](url)` to edit it — and that reason doesn't
        /// survive an atomic token, where the caret can never land inside. A plain click on a pill has
        /// nothing else it could mean; the space either side of it is where you click to type.
        func openTokenIfClicked(at point: NSPoint) -> Bool {
            guard let onOpen = parent.onOpenProject, let editor else { return false }
            let text = editor.string
            let offset = editor.characterIndexForInsertion(at: editor.convert(point, from: nil))
            guard offset <= (text as NSString).length else { return false }
            let index = String.Index(utf16Offset: offset, in: text)
            guard let span = wikilinkSpans(in: text).first(where: {
                $0.lowerBound <= index && index <= $0.upperBound
            }) else { return false }
            let name = String(text[span]).trimmingCharacters(in: CharacterSet(charactersIn: "![]"))
            onOpen(name)
            return true
        }
    }
}
