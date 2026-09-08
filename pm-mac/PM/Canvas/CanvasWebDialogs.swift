import AppKit
import WebKit

/// The panels a page is entitled to put up, and the one it isn't.
///
/// **Every one of these existed as a silent nothing.** `WKWebView` answers an unimplemented UI
/// delegate by doing nothing at all and telling nobody: `alert()` never appeared, `confirm()` returned
/// **false** without asking — so a page whose "Save" or "Delete" checks first took the "no" branch and
/// looked broken — a file input did nothing when clicked, and a site behind basic auth read as
/// "Couldn't load". A card whose links do nothing looks exactly like a card whose links work, which is
/// the failure mode this file exists to end.
///
/// Free functions on a window rather than methods on the card, because the sign-in window needs the
/// same answers and is a different class entirely. Each one calls its completion exactly once, on the
/// main actor, including the path where there is no window to hang a sheet on.
@MainActor
enum CanvasWebDialogs {

    /// `alert()`.
    static func alert(_ message: String, from host: String?, in window: NSWindow?,
                      then finish: @escaping () -> Void) {
        let panel = panel(message, from: host)
        panel.addButton(withTitle: "OK")
        run(panel, in: window) { _ in finish() }
    }

    /// `confirm()`. Cancel is the default *answer* but not the default button: the page asked a
    /// question and the page's own OK is what somebody is reaching for.
    static func confirm(_ message: String, from host: String?, in window: NSWindow?,
                        then finish: @escaping (Bool) -> Void) {
        let panel = panel(message, from: host)
        panel.addButton(withTitle: "OK")
        panel.addButton(withTitle: "Cancel")
        run(panel, in: window) { finish($0 == .alertFirstButtonReturn) }
    }

    /// `prompt()`. Nil for Cancel, which is what the page reads as a refusal.
    static func prompt(_ message: String, initial: String, from host: String?, in window: NSWindow?,
                       then finish: @escaping (String?) -> Void) {
        let panel = panel(message, from: host)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        field.stringValue = initial
        panel.accessoryView = field
        panel.addButton(withTitle: "OK")
        panel.addButton(withTitle: "Cancel")
        panel.window.initialFirstResponder = field
        run(panel, in: window) { finish($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    /// A file input. `parameters` says whether the page will take more than one.
    static func chooseFiles(_ parameters: WKOpenPanelParameters, in window: NSWindow?,
                            then finish: @escaping ([URL]?) -> Void) {
        let open = NSOpenPanel()
        open.allowsMultipleSelection = parameters.allowsMultipleSelection
        open.canChooseDirectories = parameters.allowsDirectories
        open.canChooseFiles = true
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            finish(response == .OK ? open.urls : nil)
        }
        if let window { open.beginSheetModal(for: window, completionHandler: handle) }
        else { handle(open.runModal()) }
    }

    /// A site asking who you are — basic, digest or NTLM.
    ///
    /// **The password goes straight to the challenge and nowhere else.** It is not logged, not kept in
    /// defaults and not written to the canvas; the credential is `.forSession`, so it lives as long as
    /// the app does and no longer. Anything more durable is a keychain item, which is a promise this
    /// window has no way to make honestly.
    static func signIn(to host: String, realm: String?, in window: NSWindow?,
                       then finish: @escaping (URLCredential?) -> Void) {
        let panel = NSAlert()
        panel.messageText = "Sign in to \(host)"
        panel.informativeText = realm.map { "\($0) requires a name and password." }
            ?? "This site requires a name and password."
        let name = NSTextField(frame: NSRect(x: 0, y: 26, width: 300, height: 22))
        name.placeholderString = "Name"
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        password.placeholderString = "Password"
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 48))
        fields.addSubview(name)
        fields.addSubview(password)
        panel.accessoryView = fields
        panel.addButton(withTitle: "Sign In")
        panel.addButton(withTitle: "Cancel")
        panel.window.initialFirstResponder = name
        run(panel, in: window) { response in
            guard response == .alertFirstButtonReturn, !name.stringValue.isEmpty else {
                return finish(nil)
            }
            finish(URLCredential(user: name.stringValue, password: password.stringValue,
                                 persistence: .forSession))
        }
    }

    // MARK: The shape of them

    /// A page's own words, said as the page's.
    ///
    /// Named by host, because a panel that appears over a board of twelve cards has to say which one
    /// is talking — and because a page saying "Your session has expired, sign in here" is a great deal
    /// less convincing when the window frame is naming the host it came from.
    private static func panel(_ message: String, from host: String?) -> NSAlert {
        let panel = NSAlert()
        panel.messageText = host.map { "\($0) says:" } ?? "This page says:"
        panel.informativeText = message
        return panel
    }

    /// As a sheet on the window the card is in, or as a modal panel when it has none.
    ///
    /// The fallback is not decoration: a card can be asked for a dialog while its window is closing,
    /// and a completion handler that never runs leaves the whole web process wedged behind it.
    private static func run(_ panel: NSAlert, in window: NSWindow?,
                            then finish: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.isVisible {
            panel.beginSheetModal(for: window) { finish($0) }
        } else {
            finish(panel.runModal())
        }
    }
}
