import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The "click, then press the keys" control for binding a global shortcut.
///
/// A push button rather than a text field: recording is a mode you enter and leave, and a button's
/// pressed-in look says which one you're in without any extra chrome. Its whole job is catching key
/// events that every other part of the app is trying to interpret — see `performKeyEquivalent`.
struct HotKeyRecorder: NSViewRepresentable {
    /// What's bound now, or nil for unbound.
    var combo: KeyCombo?
    /// Called with a new combination, or nil when the binding is cleared with ⌫.
    var onChange: (KeyCombo?) -> Void
    /// A refused combination, so the pane can explain why rather than just beeping.
    var onRejected: (String) -> Void = { _ in }

    func makeNSView(context: Context) -> HotKeyRecorderButton {
        let button = HotKeyRecorderButton()
        button.onChange = onChange
        button.onRejected = onRejected
        button.combo = combo
        return button
    }

    func updateNSView(_ button: HotKeyRecorderButton, context: Context) {
        button.onChange = onChange
        button.onRejected = onRejected
        // Don't overwrite the live "Type shortcut…" state with the old binding mid-recording.
        if !button.isRecording { button.combo = combo }
    }
}

final class HotKeyRecorderButton: NSButton {
    var onChange: (KeyCombo?) -> Void = { _ in }
    var onRejected: (String) -> Void = { _ in }

    var combo: KeyCombo? {
        didSet { updateTitle() }
    }

    private(set) var isRecording = false {
        didSet {
            state = isRecording ? .on : .off
            updateTitle()
        }
    }

    /// The modifiers held right now, shown while recording so you can see the combination building.
    private var liveModifiers: NSEvent.ModifierFlags = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .push
        setButtonType(.pushOnPushOff)
        target = self
        action = #selector(toggleRecording)
        updateTitle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Recording mode

    @objc private func toggleRecording() {
        if isRecording { endRecording() } else { beginRecording() }
    }

    private func beginRecording() {
        guard !isRecording else { return }
        // Our own shortcuts fire regardless of which app is in front, so ⌃⌥P aimed at this button
        // would toggle the focus panel instead of landing here. Stand them all down until we're done.
        HotKeyManager.shared.suspend()
        liveModifiers = []
        isRecording = true
        window?.makeFirstResponder(self)
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        liveModifiers = []
        HotKeyManager.shared.resume()
    }

    override func resignFirstResponder() -> Bool {
        endRecording()
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { endRecording() }
    }

    // MARK: Key capture

    /// The reason this control works at all.
    ///
    /// A window offers every key press to its views as a key equivalent *before* the menu bar or the
    /// first responder get a look, so this is the only hook that sees ⌘Q, ⌘W or ⌘, as keystrokes
    /// rather than as commands already on their way to being obeyed. Returning true consumes them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        handle(event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        liveModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        updateTitle()
    }

    private func handle(_ event: NSEvent) {
        let bare = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty

        // Escape backs out without changing anything — the standard "never mind" for a modal moment.
        if event.keyCode == UInt16(kVK_Escape), bare {
            endRecording()
            return
        }
        // ⌫ on its own clears the binding, matching how System Settings' own shortcut lists work.
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete), bare {
            onChange(nil)
            endRecording()
            return
        }
        guard let recorded = KeyCombo(event: event) else {
            // No ⌘/⌥/⌃ in the combination: it would swallow ordinary typing in every app.
            onRejected("Add ⌘, ⌥ or ⌃ — a shortcut without one would capture normal typing.")
            NSSound.beep()
            return
        }
        onChange(recorded)
        combo = recorded
        endRecording()
    }

    // MARK: Title

    private func updateTitle() {
        let text: String
        if isRecording {
            // Show the modifiers as they're held, so a half-pressed combination is visible.
            let held = KeyCombo.glyphs(for: liveModifiers)
            text = held.isEmpty ? "Type shortcut…" : held
        } else {
            text = combo?.displayString ?? "Record Shortcut"
        }
        attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: (isRecording || combo != nil)
                    ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ])
    }
}
