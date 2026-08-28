import AppKit
import SwiftUI
import XCTest
import PmLib

/// One `NSApplication`, brought up once for the whole bundle.
///
/// A hostless test bundle has no app of its own, and AppKit needs one before a window can be ordered
/// front or an event routed. `.accessory`, so nothing appears in the Dock while the tests run.
@MainActor
enum TestApp {
    private static var started = false
    static func start() {
        guard !started else { return }
        started = true
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

/// The note editor, in a window, wired the way `MarkdownTextEditor.makeNSView` wires one.
///
/// Built per test rather than shared: XCTest gives no order guarantee, and a fixture carried between
/// methods is how a suite starts depending on the order it happens to run in.
@MainActor
final class NoteEditor {
    let window: NSWindow
    let view: ShortcutTextView
    let layoutManager: TokenLayoutManager
    let container: NSTextContainer

    init(width: CGFloat = 600) {
        TestApp.start()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
        container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager = TokenLayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        view = ShortcutTextView(frame: NSRect(x: 0, y: 0, width: width, height: 300),
                                textContainer: container)
        view.isRichText = false
        view.allowsUndo = true
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    deinit { MainActor.assumeIsolated { window.orderOut(nil) } }

    var text: String { view.string }
    var caret: Int { view.selectedRange().location }
    var listIsUp: Bool { view.completions.isVisible }

    func reset(_ text: String = "") {
        view.string = text
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    func put(_ text: String, caretAt offset: Int) {
        view.string = text
        view.setSelectedRange(NSRange(location: offset, length: 0))
    }

    func type(_ string: String) {
        view.insertText(string, replacementRange: view.selectedRange())
    }

    /// Send a key the way a keyboard does.
    ///
    /// With **real characters**, not empty ones: `super.keyDown` routes through `interpretKeyEvents`,
    /// which inserts based on the event's characters. An event carrying none is a keystroke that does
    /// nothing, and a test built on those passes whether or not the key was swallowed.
    func key(_ code: Key) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: code.characters, charactersIgnoringModifiers: code.characters,
            isARepeat: false, keyCode: code.rawValue) else { return }
        view.keyDown(with: event)
    }

    func layOut() { layoutManager.ensureLayout(for: container) }

    /// The glyph property AppKit ended up with for one character — what "hidden" means in TextKit,
    /// assertable without a pixel.
    func glyphProperty(at offset: Int) -> NSLayoutManager.GlyphProperty {
        layoutManager.propertyForGlyph(at: layoutManager.glyphIndexForCharacter(at: offset))
    }

    /// How much room one character's glyph takes. A control character with a width of the layout
    /// manager's choosing is the whole difference between a pill with padding and a bare background.
    func glyphWidth(at offset: Int) -> CGFloat {
        let glyph = layoutManager.glyphIndexForCharacter(at: offset)
        return layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                          in: container).width
    }

    func regenerateGlyphs() {
        let whole = NSRange(location: 0, length: (view.string as NSString).length)
        layoutManager.invalidateGlyphs(forCharacterRange: whole, changeInLength: 0,
                                       actualCharacterRange: nil)
        layoutManager.ensureLayout(for: container)
    }

    /// Click at a point in the view's own coordinates.
    ///
    /// The matching mouse-up is queued **first**. A click the view doesn't claim falls through to
    /// `super.mouseDown`, which enters `NSTextView`'s modal tracking loop and waits for an up a test
    /// never sends — so without this the run hangs rather than fails, which is a worse way to learn
    /// the same thing.
    func click(at point: NSPoint) {
        let inWindow = view.convert(point, to: nil)
        guard let up = NSEvent.mouseEvent(with: .leftMouseUp, location: inWindow, modifierFlags: [],
                                          timestamp: 0, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 0),
              let down = NSEvent.mouseEvent(with: .leftMouseDown, location: inWindow, modifierFlags: [],
                                            timestamp: 0, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { return }
        NSApp.postEvent(up, atStart: true)
        view.mouseDown(with: down)
    }
}

/// The keys these tests press, by the code AppKit reports and the character it carries.
enum Key: UInt16 {
    case returnKey = 36
    case tab = 48
    case escape = 53
    case down = 125
    case up = 126

    var characters: String {
        switch self {
        case .returnKey: return "\r"
        case .tab: return "\t"
        case .escape: return "\u{1b}"
        case .down: return "\u{F701}"
        case .up: return "\u{F700}"
        }
    }
}

/// A window that lends token fields a `TokenFieldEditor`, exactly as `TextFocusWindow` does.
///
/// The rule itself lives in `TokenFieldEditor.wants(_:)` so there is one copy of it; this stands in
/// for the app's window, which drags in a window controller, a store and a split view none of these
/// tests want.
final class TokenLendingWindow: NSWindow {
    private lazy var tokenEditor = TokenFieldEditor()

    override func fieldEditor(_ createFlag: Bool, for client: Any?) -> NSText? {
        TokenFieldEditor.wants(client) ? tokenEditor : super.fieldEditor(createFlag, for: client)
    }
}

/// A task-list inline editor: the `NSTextField` that Add Task, Edit Task and Wrap put on screen,
/// with the coordinator that gives it the `@` / `/` loop.
///
/// The binding is held in a box rather than a SwiftUI `State`, so a test can read what the field
/// published without a view hierarchy around it.
@MainActor
final class TaskField {
    final class Box {
        var value = ""
        var submitted = false
        var cancelled = false
    }

    let box = Box()
    let window: NSWindow
    let field: TokenClickField
    let coordinator: CompletingTextField.Coordinator
    let editor: NSTextView

    /// - Parameter lendsTokenEditor: whether the window hands the field a `TokenFieldEditor`, the way
    ///   a real project window does. False gives the plain shared editor, which is what the fallback
    ///   path in the coordinator is for.
    init?(lendsTokenEditor: Bool = true) {
        TestApp.start()
        let box = self.box
        window = lendsTokenEditor
            ? TokenLendingWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 60),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            : NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 60),
                       styleMask: [.titled], backing: .buffered, defer: false)
        let representable = CompletingTextField(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            placeholder: "Task text",
            onSubmit: { box.submitted = true },
            onCancel: { box.cancelled = true },
            focusOnAppear: false)
        coordinator = representable.makeCoordinator()
        field = TokenClickField(string: "")
        field.delegate = coordinator
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        coordinator.field = field
        field.frame = NSRect(x: 10, y: 10, width: 380, height: 24)
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else { return nil }
        self.editor = editor
        coordinator.controlTextDidBeginEditing(
            Notification(name: NSControl.textDidBeginEditingNotification, object: field))
    }

    deinit { MainActor.assumeIsolated { window.orderOut(nil) } }

    var text: String { editor.string }
    var caret: Int { editor.selectedRange().location }
    var listIsUp: Bool { coordinator.completions.isVisible }

    func reset(_ text: String = "") {
        editor.string = text
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        box.value = text
        box.submitted = false
        box.cancelled = false
    }

    func type(_ string: String) {
        editor.insertText(string, replacementRange: editor.selectedRange())
        coordinator.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    /// Run one editing command through the delegate, and report whether it was claimed.
    @discardableResult
    func command(_ selector: Selector) -> Bool {
        coordinator.control(field, textView: editor, doCommandBy: selector)
    }
}
