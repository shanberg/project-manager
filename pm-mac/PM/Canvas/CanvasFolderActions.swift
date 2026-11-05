import AppKit
import Quartz

/// What a folder card does to the files in it — the Finder's commands, in the Finder's words, for the
/// list and the icons alike.
///
/// **Undoable where the Finder's are.** Moving to the Trash puts back, a rename renames back, and a
/// duplicate, an alias, an archive or a new folder goes to the Trash on undo — never deleted, since an
/// undo that destroys is not one you can undo.
///
/// **Every change reads the folder again at once**, rather than waiting the moment the folder's own
/// watch waits, so what the command made is there to be selected straight away.
@MainActor
final class CanvasFolderActions: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    unowned let browser: CanvasFolderBrowser

    init(browser: CanvasFolderBrowser) {
        self.browser = browser
    }

    private var model: CanvasFolderModel { browser.model }
    private var undo: UndoManager? { browser.window?.undoManager }
    private var files: FileManager { .default }

    // MARK: Opening

    /// Open these: a folder alone goes into the card, as a double-click in a Finder window goes into it;
    /// anything else opens in its app, and several folders open in the Finder.
    func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return NSSound.beep() }
        if urls.count == 1, CanvasFolderListing.isFolder(urls[0]), model.go(to: urls[0]) {
            browser.reloadNow()
            return
        }
        for url in urls { NSWorkspace.shared.open(url) }
    }

    func open(_ urls: [URL], with app: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// ⌘↑: the folder the one showing is in, with the one you came from selected.
    func goUp() {
        guard model.isInside else { return NSSound.beep() }
        let from = model.location
        model.go(to: model.parent)
        browser.reloadNow()
        browser.surface.select([from], scrolling: true)
    }

    // MARK: Changing files

    func trash(_ urls: [URL]) {
        var done: [(from: URL, to: URL)] = []
        for url in urls {
            var landed: NSURL?
            do {
                try files.trashItem(at: url, resultingItemURL: &landed)
                if let landed { done.append((url, landed as URL)) }
            } catch {
                NSSound.beep()
                break
            }
        }
        guard !done.isEmpty else { return }
        registerUndo("Move to Trash") { $0.putBack(done) }
        refresh()
    }

    private func putBack(_ done: [(from: URL, to: URL)]) {
        for (from, to) in done.reversed() where !files.fileExists(atPath: from.path) {
            try? files.moveItem(at: to, to: from)
        }
        registerUndo("Move to Trash") { $0.trash(done.map(\.from)) }
        refresh(selecting: done.map(\.from))
    }

    /// Rename `url` to `name`, keeping its extension when the name shown left it off — as the Finder
    /// does with extensions hidden. Answers where it went, or nil having beeped.
    @discardableResult
    func rename(_ url: URL, to name: String) -> URL? {
        guard !name.contains("/"), !name.hasPrefix(".") else { NSSound.beep(); return nil }
        var name = name
        let ext = url.pathExtension
        let shown = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
        if !ext.isEmpty, shown != url.lastPathComponent, (name as NSString).pathExtension.isEmpty {
            name += "." + ext
        }
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        guard target.path != url.path else { return url }
        let caseOnly = target.path.lowercased() == url.path.lowercased()
        guard caseOnly || !files.fileExists(atPath: target.path) else { NSSound.beep(); return nil }
        do {
            try files.moveItem(at: url, to: target)
        } catch {
            NSSound.beep()
            return nil
        }
        registerUndo("Rename") { $0.rename(target, to: url.lastPathComponent) }
        refresh(selecting: [target])
        return target
    }

    func duplicate(_ urls: [URL]) {
        var made: [URL] = []
        for url in urls {
            let target = Self.copyName(for: url, fileManager: files)
            do { try files.copyItem(at: url, to: target); made.append(target) } catch { NSSound.beep(); break }
        }
        finishMaking(made, "Duplicate")
    }

    /// The Finder's name for a copy: "name copy.ext", then "name copy 2.ext".
    static func copyName(for url: URL, fileManager: FileManager = .default) -> URL {
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        func named(_ base: String) -> URL {
            folder.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        }
        var candidate = named("\(stem) copy")
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = named("\(stem) copy \(n)")
            n += 1
        }
        return candidate
    }

    func makeAlias(_ urls: [URL]) {
        var made: [URL] = []
        for url in urls {
            let target = CanvasFolderDrop.freeName(for: url.lastPathComponent + " alias",
                                                   in: url.deletingLastPathComponent(), fileManager: files)
            do {
                let data = try url.bookmarkData(options: .suitableForBookmarkFile)
                try URL.writeBookmarkData(data, to: target)
                made.append(target)
            } catch {
                NSSound.beep()
                break
            }
        }
        finishMaking(made, "Make Alias")
    }

    /// Zip these beside themselves: "name.zip" for one, "Archive.zip" for several — the Finder's
    /// Compress, which is `ditto`'s and `zip`'s.
    func compress(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let folder = first.deletingLastPathComponent()
        let name = urls.count == 1 ? first.deletingPathExtension().lastPathComponent + ".zip" : "Archive.zip"
        let target = CanvasFolderDrop.freeName(for: name, in: folder, fileManager: files)
        let process = Process()
        if urls.count == 1 {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, target.path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = folder
            process.arguments = ["-r", "-y", "-q", target.lastPathComponent] + urls.map(\.lastPathComponent)
        }
        process.terminationHandler = { [weak self] done in
            let ok = done.terminationStatus == 0
            DispatchQueue.main.async {
                guard let self else { return }
                if ok { self.finishMaking([target], "Compress") } else { NSSound.beep() }
            }
        }
        do { try process.run() } catch { NSSound.beep() }
    }

    func newFolder() {
        let target = CanvasFolderDrop.freeName(for: "untitled folder", in: model.location, fileManager: files)
        do { try files.createDirectory(at: target, withIntermediateDirectories: false) } catch { return NSSound.beep() }
        finishMaking([target], "New Folder")
        browser.surface.beginRename(target)
    }

    /// What a command made: undoable as a trip to the Trash, and selected.
    private func finishMaking(_ made: [URL], _ actionName: String) {
        guard !made.isEmpty else { return }
        registerUndo(actionName) { actions in
            for url in made { try? actions.files.trashItem(at: url, resultingItemURL: nil) }
            actions.refresh()
        }
        refresh(selecting: made)
    }

    func copy(_ urls: [URL]) {
        guard !urls.isEmpty else { return NSSound.beep() }
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects(urls as [NSURL])
    }

    /// The files on the clipboard, copied in — the Finder's Paste Item.
    func paste() {
        let pasted = (NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !pasted.isEmpty else { return NSSound.beep() }
        do {
            let done = try CanvasFolderDrop.perform(pasted, into: model.location, copying: true)
            guard !done.isEmpty else { return }
            registerUndo(done.count == 1 ? "Paste Item" : "Paste Items") { actions in
                CanvasFolderDrop.undo(done, copied: true)
                actions.refresh()
            }
            refresh(selecting: done.map(\.to))
        } catch {
            NSSound.beep()
        }
    }

    var canPaste: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    // MARK: Tags

    /// The Finder's tag dots in a menu: every item has the tag already → take it off; otherwise put it
    /// on the ones that haven't.
    func toggleTag(_ name: String, on urls: [URL]) {
        let before = urls.map { ($0, Self.tagNames($0)) }
        let allHave = before.allSatisfy { $0.1.contains(name) }
        for (url, tags) in before {
            let after = allHave ? tags.filter { $0 != name } : (tags.contains(name) ? tags : tags + [name])
            Self.setTags(after, on: url)
        }
        registerUndo(allHave ? "Remove Tag" : "Add Tag") { actions in
            for (url, tags) in before { Self.setTags(tags, on: url) }
            actions.refresh()
        }
        refresh()
    }

    static func tagNames(_ url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }

    static func setTags(_ tags: [String], on url: URL) {
        try? (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }

    // MARK: Cloud drives

    func download(_ urls: [URL]) {
        for url in urls { try? files.startDownloadingUbiquitousItem(at: url) }
        refresh()
    }

    /// Free the space these take on this Mac; they stay on the drive.
    func removeDownload(_ urls: [URL]) {
        for url in urls { try? files.evictUbiquitousItem(at: url) }
        refresh()
    }

    // MARK: Elsewhere

    func showInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [model.location] : urls)
    }

    /// The Finder's own Get Info window, asked for by Apple event — there is no other way to open it.
    func getInfo(_ urls: [URL]) {
        let items = urls.map { "(POSIX file \"\(Self.escaped($0.path))\" as alias)" }
        guard !items.isEmpty else { return }
        let source = """
        tell application "Finder"
            activate
            open information window of {\(items.joined(separator: ", "))}
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil { NSSound.beep() }
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    func share(_ urls: [URL], in surface: CanvasFolderSurface) {
        guard let first = urls.first else { return }
        let rect = surface.rect(of: first) ?? surface.bounds
        NSSharingServicePicker(items: urls).show(relativeTo: rect, of: surface, preferredEdge: .maxY)
    }

    func addCards(_ urls: [URL]) {
        browser.host?.folderBrowser(browser, addCardsFor: urls)
    }

    func showViewOptions() {
        CanvasFolderViewOptions.shared.show(for: browser)
    }

    // MARK: Reading again

    private func refresh(selecting urls: [URL]? = nil) {
        model.refresh()
        browser.reloadNow()
        if let urls { browser.surface.select(urls, scrolling: true) }
    }

    private func registerUndo(_ name: String, _ action: @escaping (CanvasFolderActions) -> Void) {
        guard let undo else { return }
        undo.registerUndo(withTarget: self) { target in MainActor.assumeIsolated { action(target) } }
        undo.setActionName(name)
    }

    // MARK: Keys

    /// The Finder's keys on a list or a grid with the keyboard. True for a key it took.
    func handleKey(_ event: NSEvent, in surface: CanvasFolderSurface) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.contains(.command) { return handleKeyEquivalent(event, in: surface) }
        switch event.specialKey {
        case .carriageReturn?, .enter?:
            guard flags.isEmpty else { return false }
            let selected = surface.selectedURLs
            if selected.count == 1 { surface.beginRename(selected[0]) } else { NSSound.beep() }
            return true
        case .delete?, .deleteForward?, .backspace?:
            // The Finder beeps; the board would have deleted the card.
            NSSound.beep()
            return true
        default: break
        }
        if event.charactersIgnoringModifiers == " ", flags.isEmpty {
            toggleQuickLook()
            return true
        }
        if event.charactersIgnoringModifiers == "\u{1b}" {
            if isPreviewing {
                QLPreviewPanel.shared()?.orderOut(nil)
            } else {
                browser.stepOut()
            }
            return true
        }
        return false
    }

    /// The ⌘ keys, asked before the menus so a key the Finder means one thing by isn't the board's
    /// other thing while the list has the keyboard.
    func handleKeyEquivalent(_ event: NSEvent, in surface: CanvasFolderSurface) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags.contains(.command) else { return false }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let selected = surface.selectedURLs
        switch (event.specialKey, key, flags) {
        case (.downArrow?, _, [.command]): open(selected)
        case (.upArrow?, _, [.command]): goUp()
        case (.delete?, _, [.command]), (.backspace?, _, [.command]): selected.isEmpty ? NSSound.beep() : trash(selected)
        case (_, "o", [.command]): open(selected)
        case (_, "d", [.command]): selected.isEmpty ? NSSound.beep() : duplicate(selected)
        case (_, "i", [.command]): getInfo(selected.isEmpty ? [model.location] : selected)
        case (_, "j", [.command]): showViewOptions()
        case (_, "y", [.command]): toggleQuickLook()
        case (_, "a", [.command, .control]): selected.isEmpty ? NSSound.beep() : makeAlias(selected)
        case (_, "n", [.command, .shift]): newFolder()
        case (_, "r", [.command]): selected.isEmpty ? NSSound.beep() : showInFinder(selected)
        default: return false
        }
        return true
    }

    // MARK: Quick Look

    private var previewURLs: [URL] = []
    private weak var previewing: CanvasFolderSurface?

    private var isPreviewing: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true && previewing != nil
    }

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if isPreviewing { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    func beginQuickLook(_ panel: QLPreviewPanel, from surface: CanvasFolderSurface) {
        previewing = surface
        previewURLs = surface.selectedURLs
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    func endQuickLook(_ panel: QLPreviewPanel? = nil) {
        if panel == nil, QLPreviewPanel.sharedPreviewPanelExists(), let shared = QLPreviewPanel.shared(),
           shared.dataSource === self {
            shared.orderOut(nil)
        }
        previewing = nil
        previewURLs = []
    }

    /// The selection moved while Quick Look is up: it shows the new one, as the Finder's does.
    func selectionChanged() {
        guard previewing != nil, QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
              panel.dataSource === self else { return }
        previewURLs = browser.surface.selectedURLs
        panel.reloadData()
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURLs.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { previewURLs.indices.contains(index) ? previewURLs[index] as NSURL : nil }
    }

    /// Keys pressed with the panel in front still move through the list, as they do in the Finder.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        MainActor.assumeIsolated {
            guard let event, event.type == .keyDown, let previewing else { return false }
            previewing.keyDown(with: event)
            return true
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        MainActor.assumeIsolated {
            guard let url = item as? URL ?? (item as? NSURL) as URL?, let previewing,
                  let rect = previewing.rect(of: url), let window = previewing.window else { return .zero }
            return window.convertToScreen(previewing.convert(rect, to: nil))
        }
    }

    // MARK: Menus

    /// The Finder's menu for the selected items, in its order and its words — with the count in them
    /// when there are several.
    func itemMenu(for urls: [URL], in surface: CanvasFolderSurface) -> NSMenu {
        let menu = NSMenu()
        let count = urls.count
        let one = count == 1
        let quoted = one ? "“\(model.entry(for: urls[0])?.name ?? urls[0].lastPathComponent)”" : ""
        func add(_ title: String, key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command],
                 _ action: @escaping () -> Void) {
            let item = CanvasFolderMenuItem(title: title, action: action)
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
        }
        add(one ? "Open" : "Open \(count) Items", key: "o") { [weak self] in self?.open(urls) }
        if one, !CanvasFolderListing.isFolder(urls[0]), let with = openWithMenu(urls[0]) {
            let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            item.submenu = with
            menu.addItem(item)
        }
        menu.addItem(.separator())
        add(one ? "Move to Trash" : "Move \(count) Items to Trash", key: "\u{8}") { [weak self] in self?.trash(urls) }
        menu.addItem(.separator())
        add("Get Info", key: "i") { [weak self] in self?.getInfo(urls) }
        if one { add("Rename") { [weak surface] in surface?.beginRename(urls[0]) } }
        add(one ? "Compress \(quoted)" : "Compress \(count) Items") { [weak self] in self?.compress(urls) }
        add("Duplicate", key: "d") { [weak self] in self?.duplicate(urls) }
        add("Make Alias", key: "a", [.command, .control]) { [weak self] in self?.makeAlias(urls) }
        add(one ? "Quick Look \(quoted)" : "Quick Look \(count) Items", key: "y") { [weak self] in self?.toggleQuickLook() }
        menu.addItem(.separator())
        add(one ? "Copy \(quoted)" : "Copy \(count) Items", key: "c") { [weak self] in self?.copy(urls) }
        add("Share…") { [weak self, weak surface] in
            guard let self, let surface else { return }
            self.share(urls, in: surface)
        }
        menu.addItem(.separator())
        let tags = NSMenuItem()
        tags.view = CanvasFolderTagMenuView(all: urls.map(Self.tagNames)) { [weak self] name in
            self?.toggleTag(name, on: urls)
        }
        menu.addItem(tags)
        let entries = urls.compactMap(model.entry(for:))
        let onlineOnly = entries.filter { $0.sync == .onlineOnly }.map(\.url)
        let downloaded = entries.filter { !$0.isFolder && $0.sync == .none && Self.isUbiquitous($0.url) }.map(\.url)
        if !onlineOnly.isEmpty || !downloaded.isEmpty {
            menu.addItem(.separator())
            if !onlineOnly.isEmpty { add("Download Now") { [weak self] in self?.download(onlineOnly) } }
            if !downloaded.isEmpty { add("Remove Download") { [weak self] in self?.removeDownload(downloaded) } }
        }
        menu.addItem(.separator())
        add("Show in Finder", key: "r") { [weak self] in self?.showInFinder(urls) }
        add(one ? "Add Card to Board" : "Add \(count) Cards to Board") { [weak self] in self?.addCards(urls) }
        return menu
    }

    /// The Finder's menu for a window's empty space.
    func emptyMenu(in surface: CanvasFolderSurface) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command],
                 checked: Bool = false, to target: NSMenu? = nil, _ action: @escaping () -> Void) {
            let item = CanvasFolderMenuItem(title: title, action: action)
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = modifiers
            item.state = checked ? .on : .off
            (target ?? menu).addItem(item)
        }
        add("New Folder", key: "n", [.command, .shift]) { [weak self] in self?.newFolder() }
        menu.addItem(.separator())
        add("Get Info", key: "i") { [weak self] in
            guard let self else { return }
            getInfo([model.location])
        }
        if canPaste { add("Paste Item") { [weak self] in self?.paste() } }
        menu.addItem(.separator())
        let options = model.options
        let grouped = options.group != .none
        add("Use Groups", checked: grouped) { [weak self] in
            self?.browser.change(grouped ? "Don’t Use Groups" : "Use Groups") { $0.group = grouped ? .none : .kind }
        }
        if grouped {
            let groups = NSMenu()
            for group in CanvasFolderGroup.allCases where group != .none {
                add(group.title, checked: options.group == group, to: groups) { [weak self] in
                    self?.browser.change("Group by \(group.title)") { $0.group = group }
                }
            }
            let item = NSMenuItem(title: "Group By", action: nil, keyEquivalent: "")
            item.submenu = groups
            menu.addItem(item)
        }
        let sorts = NSMenu()
        for sort in CanvasFolderSort.allCases {
            add(sort.title, checked: options.sort == sort, to: sorts) { [weak self] in
                self?.browser.change("Sort by \(sort.title)") { $0.sortBy(sort, flipping: false) }
            }
        }
        let sortItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        sortItem.submenu = sorts
        menu.addItem(sortItem)
        add("Show View Options", key: "j") { [weak self] in self?.showViewOptions() }
        menu.addItem(.separator())
        add("Show in Finder") { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(model.location)
        }
        return menu
    }

    /// The apps that open `url`, its default first — the Finder's Open With.
    private func openWithMenu(_ url: URL) -> NSMenu? {
        let workspace = NSWorkspace.shared
        let main = workspace.urlForApplication(toOpen: url)
        let apps = workspace.urlsForApplications(toOpen: url)
        guard !apps.isEmpty else { return nil }
        let menu = NSMenu()
        let ordered = (main.map { [$0] } ?? []) + apps.filter { $0 != main }
        for (index, app) in ordered.enumerated() {
            var title = FileManager.default.displayName(atPath: app.path)
            if title.hasSuffix(".app") { title = String(title.dropLast(4)) }
            if index == 0, main != nil { title += " (default)" }
            let item = CanvasFolderMenuItem(title: title) { [weak self] in self?.open([url], with: app) }
            let icon = workspace.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
            if index == 0, main != nil, ordered.count > 1 { menu.addItem(.separator()) }
        }
        return menu
    }

    private static func isUbiquitous(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }
}

/// A menu item that runs a closure — the folder card's menus are built for one moment's selection.
final class CanvasFolderMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, action run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { run() }
}

/// The Finder's row of tag dots in a contextual menu: one for each of its seven colours, ringed when
/// every selected item has it.
final class CanvasFolderTagMenuView: NSView {
    private let all: [[String]]
    private let toggle: (String) -> Void
    private var hovered: Int?
    private static let side: CGFloat = 13
    private static let gap: CGFloat = 7

    init(all: [[String]], toggle: @escaping (String) -> Void) {
        self.all = all
        self.toggle = toggle
        super.init(frame: NSRect(x: 0, y: 0, width: 22 + CGFloat(CanvasFolderTag.standard.count) * (Self.side + Self.gap), height: 24))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func dot(_ index: Int) -> NSRect {
        NSRect(x: 20 + CGFloat(index) * (Self.side + Self.gap), y: (bounds.height - Self.side) / 2,
               width: Self.side, height: Self.side)
    }

    private func index(at point: NSPoint) -> Int? {
        CanvasFolderTag.standard.indices.first { dot($0).insetBy(dx: -3, dy: -3).contains(point) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = NSWorkspace.shared.fileLabelColors
        for (index, tag) in CanvasFolderTag.standard.enumerated() {
            var rect = dot(index)
            if hovered == index { rect = rect.insetBy(dx: -1.5, dy: -1.5) }
            let path = NSBezierPath(ovalIn: rect)
            (colors.indices.contains(tag.color) ? colors[tag.color] : .systemGray).setFill()
            path.fill()
            if !all.isEmpty, all.allSatisfy({ $0.contains(tag.name) }) {
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -2.5, dy: -2.5))
                ring.lineWidth = 1.2
                NSColor.labelColor.withAlphaComponent(0.6).setStroke()
                ring.stroke()
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let now = index(at: convert(event.locationInWindow, from: nil))
        if now != hovered { hovered = now; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        toggle(CanvasFolderTag.standard[index].name)
    }
}

extension CanvasFolderModel {
    /// What the card knows about `url`, from the folder showing or one opened under it.
    func entry(for url: URL) -> CanvasFolderEntry? {
        let key = CanvasFolderEntry.key(url)
        if let hit = listing.entries.first(where: { $0.key == key }) { return hit }
        for opened in children.values {
            if let hit = opened.entries.first(where: { $0.key == key }) { return hit }
        }
        return nil
    }
}
