import AppKit
import WebKit

/// Who gets a ⌘-key while the keyboard is inside a page: the page first, PM second.
///
/// **The problem.** ⌘R in Figma renames the selected frame. ⌘R in PM reloads the card — so standing
/// inside a Figma tile and pressing the key you have pressed a thousand times threw the page away
/// instead of renaming anything. The same collision is waiting on every web app worth putting on a
/// board: ⌘Z in a canvas app, ⌘E in a tracker, ⌘D anywhere. A menu bar full of one-letter shortcuts
/// and a card that is a whole other application cannot both be right about what a keystroke means.
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
        var view = window?.firstResponder as? NSView
        while let here = view {
            if here is WKWebView { return true }
            view = here.superview
        }
        return false
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
/// See `CanvasPageKeys` for what is offered and what never is.
@MainActor
final class PageFirstMenu: NSMenu {
    /// The keystroke already handed to a page, so the one WebKit hands back is answered rather than
    /// offered a second time. Identified by timestamp and code rather than held onto: it is the same
    /// `NSEvent` that comes back, and remembering two numbers keeps a dead event out of the menu bar.
    private var offered: (timestamp: TimeInterval, code: UInt16)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let handedBack = offered.map { $0.timestamp == event.timestamp && $0.code == event.keyCode }
            ?? false
        if CanvasPageKeys.offersToPage(key: CanvasPageKeys.key(of: event),
                                       modifiers: event.modifierFlags,
                                       keyboardIsInAPage: CanvasPageKeys.keyboardIsInAPage(NSApp.keyWindow),
                                       alreadyOffered: handedBack) {
            offered = (event.timestamp, event.keyCode)
            return false
        }
        return super.performKeyEquivalent(with: event)
    }
}
