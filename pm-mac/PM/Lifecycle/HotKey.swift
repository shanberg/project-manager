import AppKit
import Carbon.HIToolbox

/// One registered global hotkey, via Carbon `RegisterEventHotKey`.
///
/// Carbon rather than an `NSEvent` global monitor because Carbon hotkeys work without Accessibility or
/// Input Monitoring permission — PM asks for Full Disk Access already, and a second scary prompt to
/// bind a shortcut isn't a trade worth making.
///
/// Lifetime is ownership: hold the instance for as long as the binding should be live, drop it to
/// unregister. `HotKeyManager` is what does that holding; nothing else should construct these.
final class HotKey {
    /// Why a registration failed, for the recorder to show instead of silently doing nothing.
    enum Failure: Error {
        /// Another app (or another part of this one) already owns the combination.
        case alreadyTaken
        case registrationFailed(OSStatus)

        var message: String {
            switch self {
            case .alreadyTaken: return "In use by another app"
            case .registrationFailed(let status): return "Couldn't register (error \(status))"
            }
        }
    }

    private var ref: EventHotKeyRef?
    private let onFire: () -> Void
    private let id: UInt32

    let combo: KeyCombo

    init(combo: KeyCombo, onFire: @escaping () -> Void) throws {
        self.combo = combo
        self.onFire = onFire
        self.id = HotKey.nextID
        HotKey.nextID += 1

        HotKey.installDispatcherIfNeeded()
        HotKey.instances[id] = WeakBox(self)

        let hotKeyID = EventHotKeyID(signature: HotKey.signature, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr else {
            HotKey.instances[id] = nil
            // -9878 is `eventHotKeyExistsErr`, the one failure a person can act on: something else
            // already holds these keys.
            throw status == OSStatus(eventHotKeyExistsErr) ? Failure.alreadyTaken
                                                           : Failure.registrationFailed(status)
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.instances[id] = nil
    }

    // MARK: The shared dispatcher

    // A unique signature/id pair so the Carbon event handler can route presses back to an instance.
    private static let signature: OSType = {
        let chars = Array("PMHK".utf8)
        return (OSType(chars[0]) << 24) | (OSType(chars[1]) << 16) | (OSType(chars[2]) << 8) | OSType(chars[3])
    }()
    /// The routing table is deliberately weak.
    ///
    /// "Drop the instance to unregister" is the whole ownership model, and a strong entry here would
    /// quietly break it: the object would stay alive, `deinit` would never run, and the keys would stay
    /// claimed for the rest of the session — so rebinding a shortcut would fail as "in use by another
    /// app", by itself.
    private final class WeakBox {
        weak var hotKey: HotKey?
        init(_ hotKey: HotKey) { self.hotKey = hotKey }
    }
    private static var instances: [UInt32: WeakBox] = [:]
    private static var nextID: UInt32 = 1

    /// One handler for the whole process, installed on first use and never removed.
    ///
    /// It has to be exactly one. The handler is registered on the *dispatcher* target, so every
    /// installed handler sees every hotkey press — with one per instance, two registered hotkeys would
    /// each run their action twice, three would run it three times, and so on.
    private static var dispatcher: EventHandlerRef?

    private static func installDispatcherIfNeeded() {
        guard dispatcher == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard err == noErr, hotKeyID.signature == HotKey.signature,
                  let instance = HotKey.instances[hotKeyID.id]?.hotKey else { return noErr }
            instance.onFire()
            return noErr
        }, 1, &spec, nil, &dispatcher)
    }
}
