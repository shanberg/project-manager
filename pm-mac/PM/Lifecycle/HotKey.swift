import AppKit
import Carbon.HIToolbox

/// A single global hotkey via Carbon `RegisterEventHotKey`. Chosen over `NSEvent` global monitors
/// because Carbon hotkeys work without Accessibility/Input-Monitoring permission. Default binding is
/// Ctrl+Alt+P, matching the retired Tauri panel's summon shortcut.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onFire: () -> Void

    // A unique signature/id so the Carbon event handler can route presses back to this instance.
    private static let signature: OSType = {
        let chars = Array("PMHK".utf8)
        return (OSType(chars[0]) << 24) | (OSType(chars[1]) << 16) | (OSType(chars[2]) << 8) | OSType(chars[3])
    }()
    private static var instances: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    /// Register Ctrl+Alt+P (default). `keyCode`/`modifiers` are Carbon values.
    init?(keyCode: UInt32 = UInt32(kVK_ANSI_P),
          modifiers: UInt32 = UInt32(controlKey | optionKey),
          onFire: @escaping () -> Void) {
        self.onFire = onFire
        self.id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.instances[id] = self

        installDispatcherIfNeeded()

        var hotKeyID = EventHotKeyID(signature: HotKey.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        if status != noErr { HotKey.instances[id] = nil; return nil }
        _ = hotKeyID
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.instances[id] = nil
    }

    private var dispatcherInstalled = false
    private func installDispatcherIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if err == noErr, let instance = HotKey.instances[hkID.id] {
                instance.onFire()
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
