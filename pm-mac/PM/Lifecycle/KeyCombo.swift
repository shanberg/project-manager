import AppKit
import Carbon.HIToolbox

/// A key combination: one physical key plus its modifiers.
///
/// Stored in Carbon's vocabulary because `RegisterEventHotKey` is the only reason this type exists.
/// `NSEvent.keyCode` is the same virtual-key space, so recording from an event is a straight copy and
/// only the modifier mask needs translating. Keeping the *key code* rather than the character means a
/// binding survives a keyboard-layout change — ⌃⌥P stays on the same physical key on an AZERTY layout,
/// which is what a muscle-memory shortcut wants.
struct KeyCombo: Codable, Equatable, Hashable {
    /// A `kVK_*` virtual key code.
    var keyCode: UInt32
    /// `cmdKey | optionKey | controlKey | shiftKey`.
    var carbonModifiers: UInt32

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        self.init(keyCode: UInt32(keyCode), carbonModifiers: KeyCombo.carbon(from: modifiers))
    }

    /// Build from a recorded key-down event, or nil if the combination can't serve as a global hotkey.
    init?(event: NSEvent) {
        let carbon = KeyCombo.carbon(from: event.modifierFlags)
        // Shift alone can't carry one: ⇧A is just "A" to every other app, so registering it would
        // swallow ordinary typing system-wide. Function keys are the exception — they aren't typing.
        let hasRealModifier = carbon & UInt32(cmdKey | optionKey | controlKey) != 0
        guard hasRealModifier || KeyCombo.isFunctionKey(UInt32(event.keyCode)) else { return nil }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
    }

    // MARK: Modifiers

    static func carbon(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    // MARK: Display

    /// The shortcut as macOS writes it — ⌃⌥⇧⌘ in that order, then the key. This is what the settings
    /// pane shows and what a menu item's own rendering would produce for the same combination.
    var displayString: String { modifierGlyphs + keyName }

    var modifierGlyphs: String { KeyCombo.glyphs(for: carbonModifiers) }

    /// The modifier glyphs on their own, for showing a combination that's still being pressed.
    static func glyphs(for flags: NSEvent.ModifierFlags) -> String { glyphs(for: carbon(from: flags)) }

    static func glyphs(for carbonModifiers: UInt32) -> String {
        var out = ""
        if carbonModifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { out += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { out += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { out += "⌘" }
        return out
    }

    /// The key's name on its own: a glyph for the keys that have one, "F5"-style for function keys,
    /// and otherwise whatever character the current layout puts on that physical key.
    var keyName: String {
        if let special = KeyCombo.specialKeyNames[keyCode] { return special }
        if let character = KeyCombo.character(for: keyCode), !character.isEmpty {
            return character.uppercased()
        }
        return "Key \(keyCode)"
    }

    // MARK: Menu key equivalents

    /// The combination expressed as an `NSMenuItem` key equivalent, or nil for a key AppKit has no
    /// key-equivalent character for. Used to keep a menu item that mirrors a global hotkey honest
    /// about which keys actually fire it.
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard let key = KeyCombo.menuKeyCharacters[keyCode]
                ?? KeyCombo.character(for: keyCode)?.lowercased(), !key.isEmpty else { return nil }
        return (key, modifierFlags)
    }

    // MARK: Key names

    private static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        functionKeyNames[keyCode] != nil
    }

    private static let functionKeyNames: [UInt32: String] = [
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15", UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18", UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20",
    ]

    private static let specialKeyNames: [UInt32: String] = {
        var names: [UInt32: String] = [
            UInt32(kVK_Return): "↩",
            UInt32(kVK_ANSI_KeypadEnter): "⌤",
            UInt32(kVK_Tab): "⇥",
            UInt32(kVK_Space): "Space",
            UInt32(kVK_Delete): "⌫",
            UInt32(kVK_ForwardDelete): "⌦",
            UInt32(kVK_Escape): "⎋",
            UInt32(kVK_Help): "?⃝",
            UInt32(kVK_Home): "↖",
            UInt32(kVK_End): "↘",
            UInt32(kVK_PageUp): "⇞",
            UInt32(kVK_PageDown): "⇟",
            UInt32(kVK_LeftArrow): "←",
            UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑",
            UInt32(kVK_DownArrow): "↓",
        ]
        names.merge(functionKeyNames) { current, _ in current }
        return names
    }()

    /// The characters AppKit uses for non-printing key equivalents, for the keys where one exists.
    /// Anything absent here falls back to the layout's character, and to no menu shortcut at all if
    /// there isn't one.
    private static let menuKeyCharacters: [UInt32: String] = [
        UInt32(kVK_Return): "\r",
        UInt32(kVK_ANSI_KeypadEnter): "\u{3}",
        UInt32(kVK_Tab): "\t",
        UInt32(kVK_Space): " ",
        UInt32(kVK_Delete): "\u{8}",
        UInt32(kVK_ForwardDelete): "\u{7F}",
        UInt32(kVK_Escape): "\u{1B}",
        UInt32(kVK_Home): String(UnicodeScalar(NSHomeFunctionKey)!),
        UInt32(kVK_End): String(UnicodeScalar(NSEndFunctionKey)!),
        UInt32(kVK_PageUp): String(UnicodeScalar(NSPageUpFunctionKey)!),
        UInt32(kVK_PageDown): String(UnicodeScalar(NSPageDownFunctionKey)!),
        UInt32(kVK_LeftArrow): String(UnicodeScalar(NSLeftArrowFunctionKey)!),
        UInt32(kVK_RightArrow): String(UnicodeScalar(NSRightArrowFunctionKey)!),
        UInt32(kVK_UpArrow): String(UnicodeScalar(NSUpArrowFunctionKey)!),
        UInt32(kVK_DownArrow): String(UnicodeScalar(NSDownArrowFunctionKey)!),
    ]

    /// The character the current keyboard layout puts on a physical key, with no modifiers applied.
    /// `kUCKeyActionDisplay` is the "what's painted on the keycap" translation, which is exactly what a
    /// shortcut should show.
    private static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
