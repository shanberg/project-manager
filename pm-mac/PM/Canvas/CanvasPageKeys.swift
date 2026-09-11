import AppKit
import WebKit

/// Who gets a ⌘-key while the keyboard is inside a page: the page first, PM second.
///
/// **The problem.** A menu bar full of one-letter shortcuts and a card that is a whole other
/// application cannot both be right about what a keystroke means. ⌘Z in a canvas app is that app's
/// undo, ⌘E in a tracker is its own command, ⌘D means something different everywhere — and standing
/// inside one of those pages, the key you have pressed a thousand times ran PM's command instead.
///
/// **The rule.** While the keyboard is inside a page, a keystroke is offered to the page first. If the
/// page wants it — `preventDefault` — that is the end of it, and PM never hears about it. If the page
/// doesn't, the keystroke comes back and PM's command runs as it always did. Nothing is *taken* from
/// PM; a shortcut is only lost to a page that actively claimed it, and only while you are standing in
/// that page.
///
/// **The mechanism is WebKit's, not ours.** `WKWebView.performKeyEquivalent` hands the event to the
/// web process and, when the page turns out not to have handled it, hands it straight back to the app:
/// `WebViewImpl::doneWithKeyEvent` calls `[NSApp sendEvent:]` again *with the same `NSEvent` object*.
/// So the whole of "page first, app second" is already built; the only thing standing in front of it
/// was this app's menu bar, which AppKit offers a key equivalent to before the key window ever sees it.
/// All PM has to do is decline once — see `PageFirstMenu`.
///
/// Measured rather than assumed, in a scratch app with a page that ate ⌘R and ignored ⌘B: ⌘R reached
/// the page's handler and stopped there; ⌘B reached the page, was ignored, and arrived back at the menu
/// a moment later, same event, and fired the menu item.
///
/// **What a hung page costs.** The hand-back is a round trip through the web process, so a page that
/// has stopped answering swallows the keystroke rather than passing it on. Every browser on this Mac
/// has the same property, and the way out is the way out of any wedged tab: step out of the card
/// (Escape) and the keys are the board's again immediately.
///
/// **A key the page declines can still be an accident.** Figma was the complaint this began with, and
/// it is the case this rule does not cover: in a browser Figma leaves ⌘R alone, so the key comes back
/// and PM reloads the tile you were working in. Reload is the one command a page declines that takes
/// the page's own state with it, so handed back, it waits for a second press — see `DoubleTap`.
enum CanvasPageKeys {
    /// The keys PM keeps whatever the page says — near enough the list every browser also refuses to
    /// hand over, for the same reason: they are how you get out, and a page that could eat them could
    /// trap you in itself.
    ///
    /// Quit, close, hide, minimise, full screen and settings are the app's. New Task/Session/Project/
    /// Window, New Tab and the open commands make things, and a page has no business making them.
    /// ⌘1…9 and ⌃⇥ move between this window's tabs, ⌃1…9 between the board's frames, ⌘↩ and its
    /// variants in and out of a workspace: all of them are "take me somewhere else", which is exactly
    /// what you need when a page has gone strange. ⌘L is the address bar, which is a browser's own
    /// escape hatch and stays one here.
    ///
    /// Everything else — ⌘R, ⌘Z, ⌘E, ⌘D, ⌘[, ⌘], the zoom keys — is the page's for the asking.
    private static let kept: [(key: String, modifiers: NSEvent.ModifierFlags)] = [
        ("q", [.command]),                                                     // Quit
        ("w", [.command]), ("w", [.command, .option]),                         // Close, Close All
        ("w", [.command, .control]),                                           // Show Waiting
        (",", [.command]),                                                     // Settings
        ("h", [.command]), ("h", [.command, .option]),                         // Hide, Hide Others
        ("m", [.command]),                                                     // Minimise
        ("f", [.command, .control]),                                           // Enter Full Screen
        ("n", [.command]), ("n", [.command, .shift]), ("n", [.command, .option]),
        ("n", [.command, .control]),                                           // the New family
        ("t", [.command]),                                                     // New Tab
        ("o", [.command]), ("o", [.command, .shift]),                          // the Open family
        ("c", [.command, .option]),                                            // Show Canvas
        ("l", [.command]),                                                     // Open Address
        ("\r", [.command]), ("\r", [.command, .option]), ("\r", [.command, .shift]),
        ("\t", [.control]), ("\t", [.control, .shift]),                        // Next/Previous Tab
    ]

    /// Is this one of the keys PM keeps?
    ///
    /// Digits are a rule rather than eighteen rows: ⌘1…9 are the window's tabs and ⌃1…9 the board's
    /// frames, and both sets are numbered by however many there happen to be.
    static func keeps(key: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        let pressed = shape(modifiers)
        if key.count == 1, key.first?.isNumber == true, pressed == [.command] || pressed == [.control] {
            return true
        }
        return kept.contains { $0.key == key && $0.modifiers == pressed }
    }

    /// Should this keystroke go to the page before PM answers it?
    ///
    /// `alreadyOffered` is what stops the hand-back going round again: the event WebKit gives back is
    /// the same event, and the second time PM sees it, it is PM's.
    static func offersToPage(key: String, modifiers: NSEvent.ModifierFlags,
                             keyboardIsInAPage: Bool, alreadyOffered: Bool) -> Bool {
        guard keyboardIsInAPage, !alreadyOffered else { return false }
        // A menu key equivalent without ⌘ or ⌃ is not the kind of collision this exists for — and a
        // bare key is already the page's, because the page holds first responder.
        let pressed = shape(modifiers)
        guard pressed.contains(.command) || pressed.contains(.control) else { return false }
        return !keeps(key: key, modifiers: modifiers)
    }

    /// The keys that, once a page has handed them back, PM answers only at the second press.
    ///
    /// Reload is the whole list, because of what it throws away: every other command a page declines
    /// leaves the page as it was, and a reload takes the page's own state with it — the selection, the
    /// half-typed name, the page's undo history — with nothing in PM that could put it back. Only the
    /// key waits. The Reload item, the header's button and ⌘R on the board still reload at once,
    /// because none of those is a hand that thought it was talking to the page.
    private static let confirmed: [(key: String, modifiers: NSEvent.ModifierFlags)] = [
        ("r", [.command]),                                                     // Reload Page
    ]

    /// Should PM wait for this keystroke to be pressed a second time before answering it?
    static func asksForASecondPress(key: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        let pressed = shape(modifiers)
        return confirmed.contains { $0.key == key && $0.modifiers == pressed }
    }

    /// Is `item` the menu item this keystroke would fire?
    static func matches(_ item: NSMenuItem, key: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        !item.keyEquivalent.isEmpty && item.keyEquivalent.lowercased() == key
            && shape(item.keyEquivalentModifierMask) == shape(modifiers)
    }

    /// A keystroke as a hint writes it — ⌘R, ⇧⌘Z — with the modifiers in the order the menu bar
    /// draws them.
    static func glyphs(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        let pressed = shape(modifiers)
        let order: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"),
                                                        (.shift, "⇧"), (.command, "⌘")]
        return order.filter { pressed.contains($0.0) }.map(\.1).joined() + key.uppercased()
    }

    /// The modifiers that decide a shortcut, without the ones that only describe the keyboard.
    private static func shape(_ modifiers: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        modifiers.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function, .help])
    }

    /// How a keystroke names itself here: the letter on the key, so ⇧⌘Z and ⌘Z are both "z" and the
    /// shift is left in the modifiers where it belongs.
    static func key(of event: NSEvent) -> String {
        (event.charactersIgnoringModifiers ?? "").lowercased()
    }

    /// Is the keyboard inside a page right now?
    ///
    /// Asked of the responder rather than of the board, because "am I typing into a web page" is the
    /// whole question and every place PM shows one answers it the same way: a card you have stepped
    /// into, a tile, a sign-in window, a popup. WebKit puts its own view in front of the `WKWebView`
    /// as first responder, which is why this walks up rather than testing the responder itself.
    @MainActor
    static func keyboardIsInAPage(_ window: NSWindow?) -> Bool {
        page(in: window) != nil
    }

    /// The web view the keyboard is in, if it is in one.
    @MainActor
    static func page(in window: NSWindow?) -> WKWebView? {
        var view = window?.firstResponder as? NSView
        while let here = view {
            if let web = here as? WKWebView { return web }
            view = here.superview
        }
        return nil
    }
}

/// The app's menu bar, taught to let go.
///
/// AppKit offers a key equivalent to the main menu before the key window's views ever see it, which is
/// why a card cannot claim ⌘R for itself no matter what it does — by the time the event reaches the
/// view hierarchy the menu has already run. Declining here is the one move that puts the page in front
/// of the menu, and it is a decline rather than a redirect: PM says nothing, AppKit carries on to the
/// window, the web view takes it from there, and WebKit brings back whatever the page didn't want.
///
/// See `CanvasPageKeys` for what is offered and what never is, and `DoubleTap` for the one key that
/// comes back and still waits.
@MainActor
final class PageFirstMenu: NSMenu {
    /// The keystroke already handed to a page, so the one WebKit hands back is answered rather than
    /// offered a second time. Identified by timestamp and code rather than held onto: it is the same
    /// `NSEvent` that comes back, and remembering two numbers keeps a dead event out of the menu bar.
    private var offered: (timestamp: TimeInterval, code: UInt16)?

    private let hint = KeyHint()
    private lazy var doubleTap = DoubleTap { [weak self] text in
        guard let self else { return }
        if let text { hint.show(text, over: NSApp.keyWindow) } else { hint.hide() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let key = CanvasPageKeys.key(of: event)
        let handedBack = offered.map { $0.timestamp == event.timestamp && $0.code == event.keyCode }
            ?? false
        if CanvasPageKeys.offersToPage(key: key,
                                       modifiers: event.modifierFlags,
                                       keyboardIsInAPage: CanvasPageKeys.keyboardIsInAPage(NSApp.keyWindow),
                                       alreadyOffered: handedBack) {
            offered = (event.timestamp, event.keyCode)
            return false
        }
        if handedBack, CanvasPageKeys.asksForASecondPress(key: key, modifiers: event.modifierFlags) {
            return waitForASecondPress(event, key: key)
        }
        return super.performKeyEquivalent(with: event)
    }

    /// A key the page declined that PM won't answer the first time. See `DoubleTap`.
    private func waitForASecondPress(_ event: NSEvent, key: String) -> Bool {
        // A key held down repeats, and a repeat is not a second press: holding ⌘R would otherwise be
        // the quickest double tap there is.
        if event.isARepeat { return true }
        // A command that wouldn't run has nothing to confirm, and a hint for it would promise
        // something that isn't there. Asked of the item because its validation already knows.
        guard let item = item(for: key, modifiers: event.modifierFlags), isEnabled(item),
              let menu = item.menu else {
            return super.performKeyEquivalent(with: event)
        }
        let glyphs = CanvasPageKeys.glyphs(key: key, modifiers: event.modifierFlags)
        let page = CanvasPageKeys.page(in: NSApp.keyWindow).map(ObjectIdentifier.init)
        doubleTap.pressed(hint: "Press \(glyphs) again to \(item.title)", in: page) {
            menu.performActionForItem(at: menu.index(of: item))
        }
        return true
    }

    /// The item anywhere in the bar that answers this keystroke.
    private func item(for key: String, modifiers: NSEvent.ModifierFlags) -> NSMenuItem? {
        func search(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if CanvasPageKeys.matches(item, key: key, modifiers: modifiers) { return item }
                if let submenu = item.submenu, let found = search(submenu) { return found }
            }
            return nil
        }
        return search(self)
    }

    private func isEnabled(_ item: NSMenuItem) -> Bool {
        item.menu?.update()
        return item.isEnabled
    }
}

/// "Press ⌘R again to Reload Page": a keystroke that only counts the second time.
///
/// **Chrome's answer to ⌘Q, for the same reason.** A shortcut that throws something away, pressed
/// by a hand that learned it somewhere else, is going to be pressed by accident. Asking for it twice
/// costs the deliberate reload one more tap and makes the accident free, and because the first press
/// puts the hint up and does nothing else, the first accident also teaches how to do it on purpose.
///
/// **Twice in the same page.** The second press confirms the first, so it has to be about the same
/// thing: ⌘R in one tile, a click into another and ⌘R again is two first presses, not a reload of a
/// page you never asked about.
///
/// **Held is not twice.** A held key repeats, and the menu bar drops the repeats before they get here
/// — see `PageFirstMenu`.
@MainActor
final class DoubleTap {
    /// How long after the first press a second one counts — which is also how long the hint stays up
    /// to say so: long enough to read, gone before it's in the way.
    static let window: TimeInterval = 1.5

    private let window: TimeInterval
    /// Put the hint up (a string) or take it down (nil).
    private let display: (String?) -> Void

    /// The first press, while it's still waiting for a second: which page, and until when.
    private var waiting: (page: ObjectIdentifier?, timer: Timer)?

    init(window: TimeInterval = DoubleTap.window, display: @escaping (String?) -> Void) {
        self.window = window
        self.display = display
    }

    /// A press the page handed back. The first puts up the hint; a second in the same page, while
    /// the hint is still up, answers it.
    func pressed(hint: String, in page: ObjectIdentifier?, confirm: () -> Void) {
        if let waiting, waiting.page == page {
            waiting.timer.invalidate()
            self.waiting = nil
            display(nil)
            confirm()
            return
        }
        waiting?.timer.invalidate()
        display(hint)
        let timer = Timer.scheduledTimer(withTimeInterval: window, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.waiting = nil
                self?.display(nil)
            }
        }
        waiting = (page, timer)
    }
}

/// The hint itself: a dark rounded plate over the middle of the window, the way Chrome draws its own.
///
/// A child of the window you're in, so it rides along if the window moves, and deaf to the mouse — it
/// is something to read, and must never take a click meant for the page under it.
@MainActor
final class KeyHint {
    private(set) var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    /// Bumped by every show and hide, so a fade-out that finishes after the next show leaves it up.
    private var generation = 0

    func show(_ text: String, over window: NSWindow?) {
        guard let window else { return }
        generation += 1
        let panel = panel ?? makePanel()
        self.panel = panel
        label.stringValue = text
        let fitting = label.fittingSize
        let size = NSSize(width: ceil(fitting.width) + 48, height: ceil(fitting.height) + 28)
        let frame = window.frame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, panel.parent != nil else { return }
        generation += 1
        let fading = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == fading else { return }
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.alphaValue = 0
        panel.appearance = NSAppearance(named: .vibrantDark)

        let plate = NSVisualEffectView()
        plate.material = .hudWindow
        plate.blendingMode = .behindWindow
        plate.state = .active
        plate.wantsLayer = true
        plate.layer?.cornerRadius = 14
        plate.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 20, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
        ])
        panel.contentView = plate
        return panel
    }
}
