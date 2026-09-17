import AppKit
import WebKit

enum CatchMode: String, CaseIterable {
    case native, shim
    var title: String { self == .native ? "Native (WebKit SPI)" : "Shim (replace Notification)" }
}

enum Placement: Int, CaseIterable {
    case shown, hiddenWindow, noWindow
    var title: String { ["Shown", "Hidden window", "No window"][rawValue] }
}

enum LastNotification {
    case native(UInt64)
    case shim(Int)
}

/// One account's page: the thing a real listener would be. Logs everything it can see.
@MainActor
final class Listener: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let name: String
    let url: URL
    let mode: CatchMode
    let web: WKWebView
    var lastNotification: LastNotification?
    /// Where the page goes when it is shown. Set by the window.
    weak var container: NSView?

    private(set) var placement: Placement = .shown
    private let hiddenWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                                        styleMask: [.titled], backing: .buffered, defer: false)
    private var watches: [NSKeyValueObservation] = []
    private var heartbeat: Timer?
    private var lastProcessState: Int?
    private var ticks = 0
    private var popups: [NSWindow] = []

    init(name: String, url: URL, mode: CatchMode) {
        self.name = name
        self.url = url
        self.mode = mode
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let installed = Bundle(path: "/Applications/Safari.app")?.infoDictionary?["CFBundleShortVersionString"] as? String
        configuration.applicationNameForUserAgent = "Version/\(installed ?? "26.0") Safari/605.1.15"
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: configuration)
        super.init()
        hiddenWindow.isReleasedWhenClosed = false

        let controller = configuration.userContentController
        controller.add(WeakHandler(self), contentWorld: .defaultClient, name: "harnessObserve")
        controller.addUserScript(WKUserScript(source: Scripts.observe, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .defaultClient))
        if mode == .shim {
            controller.add(WeakHandler(self), contentWorld: .page, name: "harness")
            controller.addUserScript(WKUserScript(source: Scripts.shim, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false, in: .page))
        } else {
            let badge = SPI.set(configuration.preferences, "_setAppBadgeEnabled:", true)
            let notifications = SPI.set(configuration.preferences, "_setNotificationsEnabled:", true)
            EventLog.shared.write(name, "nativePreferences", ["appBadgeEnabled": badge, "notificationsEnabled": notifications])
            NativeNotifications.shared.attach(to: web, name: name)
        }

        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        watches.append(web.observe(\.title, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.log("title", ["title": view.title ?? ""]) }
        })
        watches.append(web.observe(\.url, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.log("url", ["url": view.url?.absoluteString ?? ""]) }
        })
        heartbeat = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
        log("created", ["url": url.absoluteString, "mode": mode.rawValue])
        web.load(URLRequest(url: url))
    }

    var pageRef: OpaquePointer? { SPI.pointer(web, "_pageRefForTransitionToWKWebView") }

    func log(_ kind: String, _ fields: [String: Any] = [:]) { EventLog.shared.write(name, kind, fields) }

    // MARK: Placement

    func place(_ placement: Placement) {
        self.placement = placement
        switch placement {
        case .shown:
            hiddenWindow.orderOut(nil)
            if let container {
                web.frame = container.bounds
                web.autoresizingMask = [.width, .height]
                container.addSubview(web)
            }
        case .hiddenWindow:
            web.removeFromSuperview()
            hiddenWindow.contentView = web
            hiddenWindow.orderFront(nil)
            hiddenWindow.orderOut(nil)
        case .noWindow:
            hiddenWindow.contentView = nil
            web.removeFromSuperview()
            hiddenWindow.orderOut(nil)
        }
        log("placement", ["placement": placement.title, "processState": processState ?? NSNull()])
    }

    // MARK: Heartbeat — only what WebKit says about the process; asking the page would wake it

    private var processState: Any? { SPI.integer(web, "_webProcessState").map { NSNumber(value: $0) } }

    private func beat() {
        ticks += 1
        let state = SPI.integer(web, "_webProcessState")
        if state != lastProcessState {
            log("processState", ["state": state.map { NSNumber(value: $0) } ?? NSNull(),
                                 "meaning": "raw _webProcessState; mapping to foreground/background/suspended not yet confirmed"])
            lastProcessState = state
        }
        if ticks % 10 == 0 {
            log("tick", ["title": web.title ?? "", "placement": placement.title,
                         "processState": state.map { NSNumber(value: $0) } ?? NSNull(),
                         "playingAudio": SPI.bool(web, "_isPlayingAudio") ?? NSNull(),
                         "pid": SPI.integer(web, "_webProcessIdentifier").map { NSNumber(value: $0) } ?? NSNull()])
        }
    }

    // MARK: Clicking the last notification — does the page open the conversation?

    func clickLastNotification() {
        switch lastNotification {
        case .native(let id)?:
            NativeNotifications.shared.click(id, listener: name)
        case .shim(let id)?:
            web.evaluateJavaScript("window.__harnessClick(\(id))", in: nil, in: .page) { [weak self] result in
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let value): self?.log("clickSent (shim)", ["result": String(describing: value)])
                    case .failure(let error): self?.log("clickFailed", ["error": error.localizedDescription])
                    }
                }
            }
        case nil:
            log("clickSkipped", ["reason": "no notification yet"])
        }
    }

    func stop() {
        heartbeat?.invalidate()
        watches.forEach { $0.invalidate() }
        web.removeFromSuperview()
        hiddenWindow.contentView = nil
        popups.forEach { $0.close() }
        log("removed")
    }

    // MARK: Messages from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        var fields = body["payload"] as? [String: Any] ?? [:]
        fields["frame"] = message.frameInfo.isMainFrame ? "main" : "sub \(message.frameInfo.securityOrigin.host)"
        if message.name == "harness" {
            if kind == "notification", let id = fields["id"] as? Int { lastNotification = .shim(id) }
            log(kind == "notification" ? "notification (shim)" : kind, fields)
        } else {
            log(kind, fields)
        }
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("loaded", ["url": webView.url?.absoluteString ?? ""])
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("processTerminated")
    }

    // MARK: UI — popups for sign-in, and the permission SPI

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Built from the passed configuration, or the opener link is lost and SSO callbacks go blank.
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 720), configuration: configuration)
        popup.uiDelegate = self
        let window = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "\(name) — sign-in popup"
        window.contentView = popup
        window.center()
        window.makeKeyAndOrderFront(nil)
        popups.append(window)
        log("popup", ["url": navigationAction.request.url?.absoluteString ?? ""])
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        popups.first { $0.contentView === webView }?.close()
        popups.removeAll { $0.contentView === webView }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        log("alert", ["message": message])
        completionHandler()
    }

    @objc(_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:)
    func webViewRequestNotificationPermission(_ webView: WKWebView, origin: WKSecurityOrigin,
                                              decisionHandler: @escaping (Bool) -> Void) {
        let string = "\(origin.protocol)://\(origin.host)\(origin.port != 0 ? ":\(origin.port)" : "")"
        log("requestPermission (native)", ["origin": string])
        NativeNotifications.shared.grant(string, from: name)
        decisionHandler(true)
    }

    @objc(_webView:updatedAppBadge:fromSecurityOrigin:)
    func webViewUpdatedAppBadge(_ webView: WKWebView, badge: NSNumber?, origin: WKSecurityOrigin) {
        log("appBadge (native)", ["count": badge ?? NSNull(), "origin": origin.host])
    }
}
