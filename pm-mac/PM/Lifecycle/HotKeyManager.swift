import AppKit
import Carbon.HIToolbox
import Combine

/// The commands that can be given a global shortcut.
///
/// Deliberately a small, fixed list rather than "every menu item": a global hotkey takes a key
/// combination away from every other app on the machine, so the only ones worth offering are the ones
/// you'd want *without* switching to PM first. Anything you'd do with a project window in front of you
/// already has a menu shortcut and doesn't belong here.
enum HotKeyAction: String, CaseIterable, Codable, Identifiable {
    case quickCapture
    case quickGoToProject
    case toggleFocusPanel
    case openProjectWindow
    case newProject
    case completeFocusedTask
    case undoLastCompletion
    case diveIn
    case revealProjectInFinder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickCapture: return "Quick Add a Task"
        case .quickGoToProject: return "Go to Project"
        case .toggleFocusPanel: return "Show or Hide Focus Panel"
        case .openProjectWindow: return "Open Focused Project"
        case .newProject: return "New Project…"
        case .completeFocusedTask: return "Complete Focused Task"
        case .undoLastCompletion: return "Undo Last Completion"
        case .diveIn: return "Dive In"
        case .revealProjectInFinder: return "Reveal Project in Finder"
        }
    }

    /// What the action is bound to out of the box.
    ///
    /// The three ways *in* to PM from another app get one: the two quick-bar modes and the focus
    /// panel. The rest ship unbound on purpose — claiming half a dozen system-wide combinations on
    /// first launch would break shortcuts in apps that have nothing to do with PM, and which keys are
    /// free is a question only the person at the keyboard can answer.
    var defaultCombo: KeyCombo? {
        switch self {
        // ⌃⌥Space and ⌃⌥O: the two ways into the quick bar, and the reason it exists — a shortcut you
        // have to go and bind first is one you won't have when you need it. Both sit next to the
        // panel's ⌃⌥P rather than near ⌘Space, which belongs to Spotlight.
        case .quickCapture:
            return KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey))
        case .quickGoToProject:
            return KeyCombo(keyCode: UInt32(kVK_ANSI_O), carbonModifiers: UInt32(controlKey | optionKey))
        // ⌃⌥P, the panel's summon shortcut since the Tauri build.
        case .toggleFocusPanel:
            return KeyCombo(keyCode: UInt32(kVK_ANSI_P), carbonModifiers: UInt32(controlKey | optionKey))
        default: return nil
        }
    }
}

/// Registers PM's global shortcuts and remembers how they're bound.
///
/// One place owns every `HotKey` instance, because a Carbon hotkey lives exactly as long as the object
/// holding it: re-binding is "drop the old one, make a new one", and that only stays coherent if a
/// single owner does it. The app delegate supplies what each action *does* once, at launch; everything
/// after that is this object rebuilding registrations as the bindings change.
@MainActor
final class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()

    /// The current binding for each action. Absent means unbound.
    @Published private(set) var bindings: [HotKeyAction: KeyCombo] = [:]

    /// Why a binding isn't live, for the actions where registration failed — almost always because
    /// another app already holds the keys. Without this the shortcut would just quietly not work.
    @Published private(set) var failures: [HotKeyAction: String] = [:]

    private var registered: [HotKeyAction: HotKey] = [:]
    private var handlers: [HotKeyAction: () -> Void] = [:]
    private var suspended = false

    private let defaults = UserDefaults.standard
    private static let storageKey = "PMGlobalHotKeys"

    private init() {
        bindings = HotKeyManager.loadBindings(from: defaults)
    }

    // MARK: Wiring

    /// Supply what each action does, and register everything that's bound. Called once, from
    /// `applicationDidFinishLaunching`.
    func start(handlers: [HotKeyAction: () -> Void]) {
        self.handlers = handlers
        registerAll()
    }

    // MARK: Reading and changing bindings

    func binding(for action: HotKeyAction) -> KeyCombo? { bindings[action] }

    /// The action already using a combination, if any — so the recorder can say what it would take
    /// over before it does.
    func action(using combo: KeyCombo, excluding action: HotKeyAction? = nil) -> HotKeyAction? {
        bindings.first { $0.key != action && $0.value == combo }?.key
    }

    /// Bind an action, or unbind it with nil.
    ///
    /// A combination can only mean one thing, so taking one that another PM action holds releases it
    /// there — the alternative is two registrations racing for the same keys, where which one wins is
    /// down to registration order.
    func setBinding(_ combo: KeyCombo?, for action: HotKeyAction) {
        if let combo, let conflicting = self.action(using: combo, excluding: action) {
            bindings[conflicting] = nil
            unregister(conflicting)
        }
        bindings[action] = combo
        saveBindings()
        register(action)
        MainMenu.syncGlobalShortcuts()
    }

    func resetToDefault(_ action: HotKeyAction) {
        setBinding(action.defaultCombo, for: action)
    }

    /// True when the action is bound to something other than what it shipped with.
    func isCustomized(_ action: HotKeyAction) -> Bool {
        bindings[action] != action.defaultCombo
    }

    // MARK: Recording

    /// Release every registration while a shortcut is being recorded, and put them back afterwards.
    ///
    /// A Carbon hotkey fires no matter which app is in front — including while you're pressing keys
    /// *at* the recorder. Without this, typing ⌃⌥P into the field would toggle the focus panel instead
    /// of being recorded.
    func suspend() {
        guard !suspended else { return }
        suspended = true
        registered.removeAll()
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        registerAll()
    }

    // MARK: Registration

    private func registerAll() {
        for action in HotKeyAction.allCases { register(action) }
        MainMenu.syncGlobalShortcuts()
    }

    private func register(_ action: HotKeyAction) {
        unregister(action)
        guard !suspended, let combo = bindings[action], let handler = handlers[action] else { return }
        do {
            registered[action] = try HotKey(combo: combo) {
                // The Carbon dispatcher runs on the main thread, so this is already where the app's
                // state lives — no hop, which keeps the shortcut feeling instant.
                MainActor.assumeIsolated { handler() }
            }
        } catch let failure as HotKey.Failure {
            failures[action] = failure.message
            Log.write("hotkey \(action.rawValue) \(combo.displayString) failed: \(failure.message)")
        } catch {
            failures[action] = "Couldn't register"
        }
    }

    private func unregister(_ action: HotKeyAction) {
        registered[action] = nil
        failures[action] = nil
    }

    // MARK: Persistence

    /// A binding is stored as a box around an optional so "the user cleared this" survives a relaunch.
    /// A missing entry means "never touched", which is what lets a default apply; an entry with no
    /// combo means "deliberately off", which a default must not override.
    private struct Stored: Codable { var combo: KeyCombo? }

    private static func loadBindings(from defaults: UserDefaults) -> [HotKeyAction: KeyCombo] {
        var result: [HotKeyAction: KeyCombo] = [:]
        let stored: [String: Stored] = {
            guard let data = defaults.data(forKey: storageKey),
                  let decoded = try? JSONDecoder().decode([String: Stored].self, from: data) else { return [:] }
            return decoded
        }()
        for action in HotKeyAction.allCases {
            if let entry = stored[action.rawValue] {
                result[action] = entry.combo
            } else {
                result[action] = action.defaultCombo
            }
        }
        return result
    }

    private func saveBindings() {
        var stored: [String: Stored] = [:]
        for action in HotKeyAction.allCases {
            stored[action.rawValue] = Stored(combo: bindings[action])
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: HotKeyManager.storageKey)
    }
}
