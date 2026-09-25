import AppKit

/// A borderless panel that can take key focus, but only when it says it needs to. `NSWindow` refuses
/// key status to borderless windows by default, and both of PM's panels host text fields that need it —
/// the focus panel's task editors, the quick bar's whole reason for existing — while the focus panel's
/// ⏎-to-complete shortcut only binds while it's key.
///
/// Gated rather than unconditional, because key status is the keyboard: whichever window holds it takes
/// every keystroke, and a floating panel that grabs it on any click leaves you typing into thin air in
/// the window you were actually working in. AppKit's own guard for this is `becomesKeyOnlyIfNeeded`,
/// which hands a panel key only for a click that lands somewhere needing text input — but it asks the
/// view under the pointer, and an `NSHostingView` answers yes at *every* point, a plain button
/// included. On a SwiftUI panel it's a no-op. So the panel decides instead: `acceptsKey` is set for the
/// paths that genuinely want the keyboard — the ⌃⌥P summon, and the panel's own editors opening — and
/// cleared as soon as key goes elsewhere.
final class KeyablePanel: NSPanel {
    /// Whether the panel may take key focus right now. Read by AppKit on every click that might move
    /// key focus, so leaving it set is what stole the keystrokes in the first place.
    var acceptsKey = false

    override var canBecomeKey: Bool { acceptsKey }

    /// Keep ⌘↩, ⌥↩, ⌃↩ and the rest for the panel's own keyboard rather than the menu bar's.
    ///
    /// A modified Return is a key equivalent before it is a keystroke, and when the panel's views
    /// decline it AppKit hands it to the main menu — whose board commands then act on the *main*
    /// window, the project window behind the panel, since a panel is never main. The quick bar reads
    /// the modifiers on Return as part of its command, so ⌥⌘↩ in it maximized a tile in the window you
    /// had left, and ⌘↩ (Create Workspace at the time) switched that window to the canvas without
    /// adding the task you typed.
    var keepsReturnKeys = false

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        // 36 is Return, 76 the keypad's Enter.
        guard keepsReturnKeys, event.type == .keyDown, [36, 76].contains(event.keyCode),
              let responder = firstResponder else { return false }
        // Where the window would have sent it had nothing claimed it as an equivalent.
        responder.keyDown(with: event)
        return true
    }

    /// Take key focus deliberately. `canBecomeKey` is consulted at this moment, so the gate opens just
    /// long enough for the panel to become key; `FocusPanelController` shuts it again on resign.
    func takeKey() {
        acceptsKey = true
        makeKey()
    }

    /// Keep controls out of the first-responder seat; only text editing gets it.
    ///
    /// The project switcher is a `Menu`, which is an `NSPopUpButton` underneath and the one view in the
    /// panel that accepts first responder — the checkbox, the open-project arrow and the Next line are
    /// all plain buttons that don't. So a click on it parks focus there for good: nothing else in the
    /// panel ever claims it back, Escape hides the window rather than dropping focus, and `takeKey`
    /// hands the same responder its ring again on the next ⌃⌥P. The result is a picker wearing a focus
    /// ring permanently, which on macOS 26 reads as a control stuck mid-press.
    ///
    /// Refused here rather than dressed down at the view: `focusEffectDisabled()` is SwiftUI's own
    /// effect and doesn't reach the ring AppKit draws for the popup, and `focusRingType = .none` on the
    /// control doesn't suppress it either. Taking the responder away is what actually clears it — which
    /// is also the honest answer, since a ring on the only focusable view marks a keyboard journey that
    /// doesn't exist. The panel's keyboard is its shortcuts and its editors, and editors are unaffected:
    /// SwiftUI focuses a `TextField` by installing the window's field editor, which isn't a control.
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if responder is NSPopUpButton { return super.makeFirstResponder(nil) }
        return super.makeFirstResponder(responder)
    }
}
