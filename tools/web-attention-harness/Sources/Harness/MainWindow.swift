import AppKit
import WebKit

@MainActor
final class MainWindowController: NSWindowController, NSTabViewDelegate {
    private static let presets: [(String, String)] = [
        ("Slack", "https://app.slack.com/client"),
        ("Discord", "https://discord.com/app"),
        ("Teams", "https://teams.microsoft.com/v2/"),
        ("Google Chat", "https://chat.google.com/"),
        ("Gmail", "https://mail.google.com/mail/u/0/"),
        ("Outlook", "https://outlook.office.com/mail/"),
        ("WhatsApp", "https://web.whatsapp.com/"),
        ("Messenger", "https://www.messenger.com/"),
        ("Telegram", "https://web.telegram.org/k/"),
        ("Linear", "https://linear.app/"),
        ("GitHub", "https://github.com/notifications"),
        ("Custom", ""),
    ]

    private let preset = NSPopUpButton()
    private let address = NSTextField()
    private let mode = NSPopUpButton()
    private let mark = NSTextField()
    private let tabs = NSTabView()
    private let logView = NSTextView()
    private var listeners: [Listener] = []

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Web Attention Harness"
        window.center()
        window.setFrameAutosaveName("HarnessMain")
        super.init(window: window)
        build()
        EventLog.shared.onLine = { [weak self] line in self?.append(line) }
        NativeNotifications.shared.listenerForPage = { [weak self] page in
            self?.listeners.first { $0.pageRef == page }
        }
        NativeNotifications.shared.watchDataStore(.default())
        EventLog.shared.write("harness", "launched", ["log": EventLog.shared.fileURL?.path ?? "window only",
                                                      "os": ProcessInfo.processInfo.operatingSystemVersionString])
        if let test = ProcessInfo.processInfo.environment["HARNESS_SELFTEST"], let url = URL(string: test) {
            selfTest(url)
        } else {
            restore()
        }
    }

    /// Both modes against one page, a click on each, then quit — so the harness can be checked without
    /// anybody's accounts. Nothing is saved.
    private func selfTest(_ url: URL) {
        EventLog.shared.write("harness", "selfTest", ["url": url.absoluteString])
        if let host = url.host { NativeNotifications.shared.grant("\(url.scheme ?? "http")://\(host)\(url.port.map { ":\($0)" } ?? "")", from: "harness") }
        open(name: "test · native", url: url, mode: .native)
        open(name: "test · shim", url: url, mode: .shim)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.listeners.forEach { $0.clickLastNotification() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
            self?.listeners.forEach { $0.place(.noWindow) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 11) { NSApp.terminate(nil) }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Building the window

    private func build() {
        for (name, _) in Self.presets { preset.addItem(withTitle: name) }
        preset.target = self
        preset.action = #selector(presetChanged)
        address.placeholderString = "https://…"
        address.stringValue = Self.presets[0].1
        address.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        for catchMode in CatchMode.allCases { mode.addItem(withTitle: catchMode.title) }
        let add = NSButton(title: "Add Listener", target: self, action: #selector(addListener))
        add.keyEquivalent = "\r"
        mark.placeholderString = "Note what you just did — e.g. “DM’d myself in workspace B”"
        mark.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        mark.target = self
        mark.action = #selector(writeMark)
        let markButton = NSButton(title: "Mark", target: self, action: #selector(writeMark))
        let reveal = NSButton(title: "Reveal Log", target: self, action: #selector(revealLog))
        reveal.isHidden = EventLog.shared.fileURL == nil

        let top = NSStackView(views: [preset, address, mode, add, NSView(), mark, markButton, reveal])
        top.orientation = .horizontal
        top.spacing = 8
        top.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        tabs.delegate = self
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = logView
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.autoresizingMask = [.width]
        logView.isVerticallyResizable = true
        logView.textContainer?.widthTracksTextView = true

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(tabs)
        split.addArrangedSubview(scroll)

        let root = NSStackView(views: [top, split])
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .leading
        top.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        split.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        window?.contentView = root
        DispatchQueue.main.async { split.setPosition(620, ofDividerAt: 0) }
    }

    private func append(_ line: String) {
        let atBottom = (logView.enclosingScrollView?.verticalScroller?.floatValue ?? 1) > 0.98
        logView.textStorage?.append(NSAttributedString(string: line + "\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.textColor]))
        if atBottom { logView.scrollToEndOfDocument(nil) }
    }

    // MARK: Listeners

    @objc private func presetChanged() {
        address.stringValue = Self.presets[preset.indexOfSelectedItem].1
    }

    @objc private func addListener() {
        guard let url = URL(string: address.stringValue.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
            NSSound.beep()
            return
        }
        let base = Self.presets[preset.indexOfSelectedItem].0 == "Custom" ? (url.host ?? "page") : Self.presets[preset.indexOfSelectedItem].0
        let catchMode = CatchMode.allCases[mode.indexOfSelectedItem]
        var name = "\(base) · \(catchMode.rawValue)"
        var n = 2
        while listeners.contains(where: { $0.name == name }) { name = "\(base) · \(catchMode.rawValue) \(n)"; n += 1 }
        open(name: name, url: url, mode: catchMode)
        save()
    }

    private func open(name: String, url: URL, mode: CatchMode) {
        let listener = Listener(name: name, url: url, mode: mode)
        listeners.append(listener)

        let placement = NSSegmentedControl(labels: Placement.allCases.map(\.title), trackingMode: .selectOne,
                                           target: self, action: #selector(placementChanged(_:)))
        placement.selectedSegment = 0
        let click = NSButton(title: "Click Last Notification", target: self, action: #selector(clickLast(_:)))
        let reload = NSButton(title: "Reload", target: self, action: #selector(reload(_:)))
        let remove = NSButton(title: "Remove", target: self, action: #selector(remove(_:)))
        let label = NSTextField(labelWithString: "\(mode.title) — \(url.absoluteString)")
        label.textColor = .secondaryLabelColor
        let controls = NSStackView(views: [placement, click, reload, NSView(), label, remove])
        controls.orientation = .horizontal
        controls.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        let container = NSView()
        let page = NSStackView(views: [controls, container])
        page.orientation = .vertical
        page.spacing = 0
        controls.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        container.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true

        let item = NSTabViewItem(identifier: name)
        item.label = name
        item.view = page
        tabs.addTabViewItem(item)
        tabs.selectTabViewItem(item)
        listener.container = container
        DispatchQueue.main.async { listener.place(.shown) }
    }

    private func listener(for sender: NSView) -> Listener? {
        guard let name = tabs.selectedTabViewItem?.identifier as? String else { return nil }
        return listeners.first { $0.name == name }
    }

    @objc private func placementChanged(_ sender: NSSegmentedControl) {
        listener(for: sender)?.place(Placement(rawValue: sender.selectedSegment) ?? .shown)
    }

    @objc private func clickLast(_ sender: NSButton) { listener(for: sender)?.clickLastNotification() }

    @objc private func reload(_ sender: NSButton) {
        guard let listener = listener(for: sender) else { return }
        listener.log("reload")
        listener.web.reload()
    }

    @objc private func remove(_ sender: NSButton) {
        guard let listener = listener(for: sender), let item = tabs.selectedTabViewItem else { return }
        listener.stop()
        listeners.removeAll { $0 === listener }
        tabs.removeTabViewItem(item)
        save()
    }

    @objc private func writeMark() {
        let text = mark.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        EventLog.shared.write("you", "mark", ["note": text])
        mark.stringValue = ""
    }

    @objc private func revealLog() {
        guard let file = EventLog.shared.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    // MARK: Remembering the listeners — signed-in sessions persist in the default data store

    private func save() {
        UserDefaults.standard.set(listeners.map { ["name": $0.name, "url": $0.url.absoluteString, "mode": $0.mode.rawValue] },
                                  forKey: "listeners")
    }

    private func restore() {
        let saved = UserDefaults.standard.array(forKey: "listeners") as? [[String: String]] ?? []
        for entry in saved {
            guard let name = entry["name"], let url = entry["url"].flatMap(URL.init(string:)),
                  let mode = entry["mode"].flatMap(CatchMode.init(rawValue:)) else { continue }
            open(name: name, url: url, mode: mode)
        }
    }

    // A tab switched away from is still "shown" in the harness's sense only if its placement says so;
    // NSTabView removes the view from the window, which is its own kind of hidden. Say so in the log.
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard let name = tabViewItem?.identifier as? String else { return }
        EventLog.shared.write("harness", "tabSelected", ["page": name])
    }
}
