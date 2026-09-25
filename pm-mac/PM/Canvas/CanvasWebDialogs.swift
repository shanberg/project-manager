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
/// Free functions rather than methods on the card, because the popup needs the same answers and is a
/// different class entirely. Each one calls its completion exactly once, on the main actor, including
/// the path where there is nothing to put it over.
///
/// **Over the tile that asked** (`CanvasTileAlert`), given an `anchor` — the card, or its content when
/// the card is out in a window of its own. A sheet only where there is no anchor, and a modal panel
/// where there isn't even a window.
@MainActor
enum CanvasWebDialogs {

    /// `alert()`.
    static func alert(_ message: String, from host: String?, over anchor: NSView? = nil, in window: NSWindow?,
                      then finish: @escaping () -> Void) {
        var panel = panel(message, from: host)
        panel.buttons = ["OK"]
        run(panel, over: anchor, in: window) { _ in finish() }
    }

    /// `confirm()`. Cancel is the default *answer* but not the default button: the page asked a
    /// question and the page's own OK is what somebody is reaching for.
    static func confirm(_ message: String, from host: String?, over anchor: NSView? = nil, in window: NSWindow?,
                        then finish: @escaping (Bool) -> Void) {
        var panel = panel(message, from: host)
        panel.buttons = ["OK", "Cancel"]
        run(panel, over: anchor, in: window) { finish($0 == 0) }
    }

    /// `prompt()`. Nil for Cancel, which is what the page reads as a refusal.
    static func prompt(_ message: String, initial: String, from host: String?, over anchor: NSView? = nil,
                       in window: NSWindow?, then finish: @escaping (String?) -> Void) {
        var panel = panel(message, from: host)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.stringValue = initial
        panel.accessory = field
        panel.initialFirstResponder = field
        panel.buttons = ["OK", "Cancel"]
        run(panel, over: anchor, in: window) { finish($0 == 0 ? field.stringValue : nil) }
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
    static func signIn(to host: String, realm: String?, over anchor: NSView? = nil, in window: NSWindow?,
                       then finish: @escaping (URLCredential?) -> Void) {
        let name = NSTextField(frame: NSRect(x: 0, y: 30, width: 240, height: 22))
        name.placeholderString = "Name"
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        password.placeholderString = "Password"
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 52))
        fields.addSubview(name)
        fields.addSubview(password)
        let panel = CanvasTileAlert.Content(
            title: "Sign in to \(host)",
            message: realm.map { "\($0) requires a name and password." } ?? "This site requires a name and password.",
            icon: NSApp.applicationIconImage, accessory: fields, initialFirstResponder: name,
            buttons: ["Sign In", "Cancel"])
        run(panel, over: anchor, in: window) { response in
            guard response == 0, !name.stringValue.isEmpty else {
                return finish(nil)
            }
            finish(URLCredential(user: name.stringValue, password: password.stringValue,
                                 persistence: .forSession))
        }
    }

    /// A page asking for the camera or the microphone — a call, a huddle, a voice note.
    ///
    /// **Asked once per site, and the answer kept** in `CanvasSiteSettings`, where Settings lists it and
    /// can change it. Once, because a site that holds calls asks at the start of every call, and a
    /// question put that often stops being read. Per site rather than per card, because that is the
    /// unit someone trusts: Slack in any card, or the huddle it pops out, is the same Slack.
    ///
    /// Requests that arrive while the question is up — a page that asks for the camera and the
    /// microphone separately — wait for the same answer rather than stacking a second sheet.
    static func mediaAccess(for host: String, _ type: WKMediaCaptureType, over anchor: NSView? = nil,
                            in window: NSWindow?,
                            then finish: @escaping (WKPermissionDecision) -> Void) {
        switch CanvasSiteSettings.site(for: host).media {
        case .allow: return finish(.grant)
        case .deny: return finish(.deny)
        case .ask: break
        }
        let key = CanvasBlockPolicy.siteKey(for: host)
        if pendingMedia[key] != nil { pendingMedia[key]?.append(finish); return }
        pendingMedia[key] = [finish]
        let wants = type == .camera ? "the camera" : type == .microphone ? "the microphone"
                                                                        : "the camera and microphone"
        let panel = CanvasTileAlert.Content(
            title: "Allow \(host) to use \(wants)?",
            message: "Folio remembers this for \(key). You can change it in Settings, under Sites.",
            icon: NSApp.applicationIconImage, buttons: ["Allow", "Don't Allow"])
        run(panel, over: anchor, in: window) { response in
            let allowed = response == 0
            CanvasSiteSettings.update(host) { $0.media = allowed ? .allow : .deny }
            let waiting = pendingMedia.removeValue(forKey: key) ?? []
            waiting.forEach { $0(allowed ? .grant : .deny) }
        }
    }

    private static var pendingMedia: [String: [(WKPermissionDecision) -> Void]] = [:]

    // MARK: The shape of them

    /// A page's own words, said as the page's.
    ///
    /// Named by host, because a panel that appears over a board of twelve cards has to say which one
    /// is talking — and because a page saying "Your session has expired, sign in here" is a great deal
    /// less convincing when the window frame is naming the host it came from.
    private static func panel(_ message: String, from host: String?) -> CanvasTileAlert.Content {
        CanvasTileAlert.Content(title: host.map { "\($0) says:" } ?? "This page says:", message: message,
                                icon: NSApp.applicationIconImage, buttons: [])
    }

    /// Over the tile that asked; else as a sheet on the window; else as a modal panel. Answers with
    /// the index of the button pressed, in the order `panel.buttons` lists them.
    ///
    /// The fallbacks are not decoration: a card can be asked for a dialog while its window is closing,
    /// and a completion handler that never runs leaves the whole web process wedged behind it.
    static func run(_ panel: CanvasTileAlert.Content, over anchor: NSView?, in window: NSWindow?,
                    then finish: @escaping (Int) -> Void) {
        if let anchor, ((anchor as? CanvasTileAlert.Asker)?.alertAnchor ?? anchor).window?.isVisible == true,
           CanvasTileAlert.present(panel, over: anchor, then: finish) != nil {
            return
        }
        let alert = NSAlert()
        alert.messageText = panel.title
        alert.informativeText = panel.message
        alert.accessoryView = panel.accessory
        panel.buttons.forEach { alert.addButton(withTitle: $0) }
        alert.window.initialFirstResponder = panel.initialFirstResponder
        let index: (NSApplication.ModalResponse) -> Int = { $0.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue }
        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { finish(index($0)) }
        } else {
            finish(index(alert.runModal()))
        }
    }
}
