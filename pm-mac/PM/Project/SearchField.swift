import SwiftUI
import AppKit

/// A real `NSSearchField`.
///
/// SwiftUI's search control is `.searchable`, which places itself in the window's toolbar — and this
/// window deliberately has no toolbar, so there's nowhere for it to go. A plain `TextField` would look
/// close and behave wrong: no magnifier, no clear button, no Escape-clears-then-cancels, none of the
/// search-field affordances a Mac user's hands already know. So the control is bridged rather than
/// approximated.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder = "Search"
    /// Bumped by the caller to pull keyboard focus into the field — on opening the find bar, and again
    /// if ⌘F is pressed while it's already open (which, as in Safari, re-focuses and selects).
    var focusToken = 0
    /// Escape in an already-empty field. The field clears itself first; this is the second press.
    var onCancel: () -> Void = {}
    /// Return in the field — hands focus back to the list so the arrow keys work on the results.
    var onCommit: () -> Void = {}

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        // Fire on every keystroke rather than on Return: this filters a list that's already on screen,
        // so waiting for a commit would make it feel like a query rather than a filter.
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        guard context.coordinator.lastFocusToken != focusToken else { return }
        context.coordinator.lastFocusToken = focusToken
        // `updateNSView` runs inside a layout pass, and taking first responder from there re-enters
        // SwiftUI's update.
        afterCurrentUpdate {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private let parent: SearchField
        var lastFocusToken = 0
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                // Escape clears a field with text in it (the field's own behaviour, so let it through);
                // Escape in an empty field closes the bar.
                guard control.stringValue.isEmpty else { return false }
                parent.onCancel()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onCommit()
                return true
            default:
                return false
            }
        }
    }
}
