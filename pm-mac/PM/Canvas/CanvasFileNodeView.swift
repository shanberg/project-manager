import AppKit
import Combine
import SwiftUI
import PDFKit
import PmLib
import WebKit

/// A card showing a file from the vault: a note, a picture, a PDF.
///
/// **The card is the file's contents and nothing else.** It used to carry a header strip naming the
/// file, which was doing two jobs. Identifying the card is the smaller one, and the note's own first
/// heading usually does it better; what is left of it is what the card tells the header and VoiceOver,
/// and zoomed out the filename
/// becomes the card's whole content, because at that size the name genuinely is the most informative
/// thing about it.
///
/// The larger job was saying that the file isn't where the canvas claims. A canvas stores a path from
/// the vault root and never updates it, so when PM archives or renumbers a project every card pointing
/// into it goes stale — in a real vault, nearly half of them had. `CanvasFileResolver` still follows
/// those to where the file actually went, and the window says so once, at the top, with Repair Paths
/// beside it — which is the better place for it anyway: it is a fact about the document rather than
/// about any one card, and it was only ever readable on the cards you happened to scroll past.
///
/// A card whose file is genuinely gone draws as missing **with the path it wanted**, rather than as an
/// empty rectangle. The path is the only clue to what was there.
@MainActor
final class CanvasFileNodeView: CanvasNodeView {
    private var location: CanvasFileLocation = .missing

    /// The project this card shows, when it shows one — its store, and the key the registry knows it
    /// by so the hold can be given back. Shared with the project window (`StoreRegistry`), so a task
    /// ticked here is ticked there, with no second copy of the document to keep in step.
    private var projectStore: PMStore?
    private var projectStoreKey: String?
    /// Published to this card's SwiftUI content, which starts scrolling and stops holding an open
    /// editor as you step in and out.
    private let engagement = CanvasCardEngagement()
    /// The other direction: what the board asks of this card when it is the one you are standing in —
    /// New Session, New Task. Held here rather than made per render, so a command survives the card
    /// rebuilding its content (a zoom threshold, a re-resolved path) with an editor open.
    let projectCommands = CanvasProjectCardCommands()
    /// This card's live copy of what it shows. Kept in step with the node by `update`, and published
    /// to the SwiftUI content so the change is a redraw rather than a rebuild.
    ///
    /// Not private: the window's find writes its query here while this is the card you are standing
    /// in, and reads the match count back out — see `CanvasPaneController.search`.
    let projectDisplay = CanvasProjectCardDisplay()

    /// What this card is set to draw of its project, as the document says.
    var shows: CanvasCardShows { CanvasCardShows.of(node) }
    /// Watches the project's undo stack, which is how this card knows an edit happened to it — from
    /// here, from the project's own window, or from anywhere else holding the same store.
    private var projectEdits: ObservationRelay?
    private var lastUndoDepth = 0
    /// The listing this card shows when its path is a folder, watched while the card is up. See
    /// `CanvasFolderCard`.
    private var folder: CanvasFolderModel?
    /// The folder this card lists, when it is a folder card — what a file drop is filed into.
    var folderModel: CanvasFolderModel? { folder }

    override init(node: CanvasNode, board: CanvasBoardView, scale: Double) {
        super.init(node: node, board: board, scale: scale)
        contentChanged()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var stored: (path: String, subpath: String?) {
        if case .file(let path, let subpath) = node.content { return (path, subpath) }
        return ("", nil)
    }

    /// The node changed. Beyond what the base class watches — the content and the zoom — this card has
    /// a setting of its own in `extra`, and it is deliberately *not* a rebuild: assigning it publishes,
    /// and the SwiftUI content redraws around whatever it was holding.
    ///
    /// Guarded on a difference because `update` runs on every document change and every layout pass,
    /// and an unguarded write to an observed property does not care whether the value moved.
    override func update(node: CanvasNode, scale: Double) {
        super.update(node: node, scale: scale)
        let wanted = CanvasCardShows.of(node)
        if projectDisplay.shows != wanted { projectDisplay.shows = wanted }
        let pinned = CanvasSittingPin.of(node)
        if projectDisplay.sitting != pinned { projectDisplay.sitting = pinned }
        let options = CanvasFolderOptions.of(node)
        if let folder, folder.options != options { folder.options = options }
    }

    override func contentChanged() {
        let (path, subpath) = stored
        location = board.store.resolver.resolve(path)
        // The card may have been pointed somewhere else entirely. A hold on the project it used to show
        // is a project kept open for a card that has stopped showing it.
        if projectStoreKey != nil,
           projectStoreKey != location.url.flatMap(CanvasProjectSource.projectKey(for:)) {
            releaseProject()
        }

        // Zoomed out, a note renders as a grey texture and a PDF page as a grey rectangle, and both
        // cost a full layout to produce. The filename is what you are actually reading at this size.
        // Pictures are the exception and keep rendering: an image is *more* legible small than any
        // text, and at this zoom it is usually the only thing on the board you can identify.
        let isFolder = location.url.map(CanvasFolderListing.isFolder) ?? false
        if folder != nil, !isFolder || folder?.url != location.url { releaseFolder() }
        if isSimplified, !isPicture(path) {
            CanvasFileWatch.shared.stop(self)
            setContent(summaryView(canvasFileCardName(path, isFolder: isFolder),
                                   symbol: canvasFileSymbol(path, isFolder: isFolder)))
            return
        }

        setContent(preview(for: location, path: path, subpath: subpath))
        watchFile(isFolder: isFolder)
    }

    // MARK: Noticing the file change

    /// Follow the file this card draws, so an edit made in Obsidian — or anywhere — shows here without
    /// the card having to be scrolled away and back. See `CanvasFileWatch`.
    ///
    /// Not a project, whose store watches its own notes; not a folder, which `CanvasFolderCard`
    /// watches; not a web page from disk, where a reload would throw away where you'd scrolled to for a
    /// change you are probably making in the page's own editor.
    private func watchFile(isFolder: Bool) {
        guard let url = location.url, !isFolder, !isProjectCard,
              isProse(url.path) || isPicture(url.path) || url.pathExtension.lowercased() == "pdf"
        else { return CanvasFileWatch.shared.stop(self) }
        CanvasFileWatch.shared.watch(self, url) { [weak self] in self?.fileChanged() }
    }

    /// The file changed on disk. Drawn again when you are only looking at it. While you are writing in
    /// it, the file's version is taken only if you have nothing unsaved — otherwise yours stands, and is
    /// written over it half a second later, because the alternative is throwing away what you just typed.
    private func fileChanged() {
        guard let session = document else {
            // Gone, or moved: ask afresh where it is rather than trusting the answer from before.
            if location.url.map({ !FileManager.default.fileExists(atPath: $0.path) }) == true {
                board.store.resolver.refresh()
            }
            return contentChanged()
        }
        guard let disk = try? String(contentsOf: session.url, encoding: .utf8),
              disk != session.synced else { return }
        guard !session.hasUnsavedEdits else {
            Log.write("\(session.url.lastPathComponent) changed on disk while it had unsaved typing; keeping the typing")
            return
        }
        session.adopt(disk)
        // Into the editor as an edit it knows about, so ⌘Z still lines up — see `replaceFromOutside`.
        (firstTextView as? ShortcutTextView)?.replaceFromOutside(disk)
    }

    /// What the card says about itself when asked: which file, which heading, and whether PM had to go
    /// looking for it. See `CanvasNodeView.cardDescription`.
    override var cardDescription: String? {
        let (path, subpath) = stored
        guard !path.isEmpty else { return nil }
        var lines = [(path as NSString).lastPathComponent
                        + (subpath.map { " \u{00B7} " + $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")) } ?? "")]
        if let moved = movedNote { lines.append(moved) }
        return lines.joined(separator: "\n")
    }

    /// What the card says when PM had to go looking. Names the folder it landed in, because "moved" on
    /// its own doesn't tell you whether the project was archived or renamed.
    private var movedNote: String? {
        guard case .moved(let url, _) = board.store.resolver.resolve(stored.path) else { return nil }
        let parent = url.deletingLastPathComponent()
        let root = obsidianVaultRoot(for: url)
        let where_ = root.flatMap { CanvasFileResolver(canvas: url, vaultRoot: $0).storablePath(for: parent) }
        return "moved to " + (where_ ?? parent.lastPathComponent)
    }

    /// The project this card's file belongs to, if it is a project's notes. What the menu's Open
    /// Project acts on.
    var projectFolderName: String? {
        projectFolder(ofNotesPath: stored.path).map { ($0 as NSString).lastPathComponent }
    }

    /// Prose scrolls; a picture and a PDF preview do not.
    ///
    /// The PDF is deliberate rather than an omission — a PDF card is one page scaled to fit, with no
    /// scrolling by design (see `preview`), so there is nothing under the pointer to travel through.
    override var scrollsItsContent: Bool {
        isProse(stored.path) || location.url.map(CanvasFolderListing.isFolder) == true
    }

    /// A note shown as prose — not a project, not a folder — which is set like a typed card and
    /// written in place like one. See `CanvasDocCards`.
    override var setsProse: Bool {
        isProse(stored.path) && !isProjectCard && location.url.map(CanvasFolderListing.isFolder) != true
    }

    /// Its text answers ⌘+ and ⌘− the way a typed card's does.
    override var zoomsItsContent: Bool { setsProse }

    override func contentZoomChanged() {
        if setsProse { contentChanged() }
    }

    /// Whether a double-click writes in this card rather than sending you to Obsidian: a note that is
    /// there, shown whole. A card showing one `#Heading` of a note still opens the note — editing a
    /// slice of a file in place would mean writing back around text you can't see.
    private var writesInPlace: Bool {
        setsProse && stored.subpath == nil && location.url != nil
    }

    private func isProse(_ path: String) -> Bool {
        ["md", "markdown", "txt"].contains((path as NSString).pathExtension.lowercased())
    }

    private func isPicture(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]
            .contains((path as NSString).pathExtension.lowercased())
    }

    /// The card's body: the file, drawn as the kind of thing it is.
    private func preview(for location: CanvasFileLocation, path: String, subpath: String?) -> NSView {
        guard let url = location.url else { return missingView(path) }

        if CanvasFolderListing.isFolder(url) {
            let model = folder ?? CanvasFolderModel(url: url, options: CanvasFolderOptions.of(node))
            folder = model
            return NSHostingView(rootView: CanvasFolderCard(folder: model).canvasLinkZones(linkZones))
        }

        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp":
            // Fitted, or filling the card when the card is nearly the picture's own shape — which is
            // what keeps a board of photographs from being a board of grey margins. See
            // `CanvasPictureView`, which owns that judgement and the reason it is not a setting.
            let image = CanvasPictureView()
            image.image = NSImage(contentsOf: url)
            image.setAccessibilityLabel(url.lastPathComponent)
            return image

        case "pdf":
            // A PDF card is a *preview*, so the view is stripped of everything that would invite
            // interaction it isn't going to get: one page, scaled to the card, no scrolling, no
            // shadow. Opening it properly is what the strip's button is for.
            let view = PDFView()
            view.document = PDFDocument(url: url)
            view.autoScales = true
            view.displayMode = .singlePage
            view.displaysPageBreaks = false
            view.backgroundColor = .clear
            return view

        case "md", "markdown", "txt":
            // A project's notes are a project, not a markdown file — see `CanvasProjectNote`. Only for
            // the whole document: a `#Heading` subpath is a request for one part of the file, and the
            // task list is not a part of a file, so a card pointing into one falls through to prose.
            if subpath == nil, let store = projectStore(for: url) {
                return NSHostingView(rootView:
                    CanvasProjectNote(store: store, engagement: engagement, noteURL: url,
                                      onOpenProject: { folder in
                                          WindowManager.shared.open(named: folder)
                                      },
                                      commands: projectCommands, display: projectDisplay)
                        .canvasLinkZones(linkZones))
            }
            if let document { return documentEditor(document, url: url) }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let shown = subpath.flatMap { section(named: $0, in: text) } ?? text
            return NSHostingView(rootView:
                CanvasRenderedProse(prose: shown, style: textStyle, zoom: contentZoom,
                                    noteURL: url, maxImageHeight: 320)
                .canvasLinkZones(linkZones))

        case "html", "htm", "xhtml":
            // A page, drawn as one. See `CanvasHTMLFileView`.
            return CanvasHTMLFileView(url: url)

        default:
            let label = NSTextField(labelWithString: url.lastPathComponent)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            return label
        }
    }

    /// The project's store, taken from the registry the first time this card asks and held until the
    /// card goes away.
    ///
    /// Retained rather than fetched per render, because acquiring is what triggers the project's first
    /// read: asking again on every rebuild would be a reload per zoom threshold crossed.
    private func projectStore(for url: URL) -> PMStore? {
        if let projectStore { return projectStore }
        guard let key = CanvasProjectSource.projectKey(for: url) else { return nil }
        let store = StoreRegistry.shared.acquire(key)
        projectStore = store
        projectStoreKey = key
        // Every mutation pushes a snapshot, so the stack growing *is* an edit — whoever made it, and
        // whichever surface they made it on. Watching that rather than wrapping each call site is what
        // catches the ones made through `TaskMenu`, which talks to the store directly.
        lastUndoDepth = store.undoStack.count
        projectEdits = ObservationRelay(tracking: { [weak store] in _ = store?.undoStack }) {
            [weak self, weak store] in
            guard let self, let store else { return }
            let depth = store.undoStack.count
            defer { lastUndoDepth = depth }
            guard depth > lastUndoDepth else { return }
            board.lastEditedProject = store
        }
        return store
    }

    /// The folder this card lists, when its path is one — what Change Folder… starts from. See
    /// `CanvasFolderCard`.
    var folderURL: URL? {
        location.url.flatMap { CanvasFolderListing.isFolder($0) ? $0 : nil }
    }

    /// Whether this card shows a project rather than a file.
    ///
    /// Asked of the path, not of whether the store happens to be held. A card zoomed out past reading
    /// draws a summary and never acquires a store, and what a click on it means should not depend on
    /// how far out the board happens to be.
    var isProjectCard: Bool {
        guard stored.subpath == nil, let url = location.url else { return false }
        return CanvasProjectSource.projectKey(for: url) != nil
    }

    /// A card showing a project takes its own clicks, the way a web card does — you tick a box, retype
    /// a task, set a date. Everything else on a board is read, so everything else waits for a
    /// double-click.
    override var engagesOnClick: Bool { isProjectCard && !isSimplified }

    /// Cheap to ask on every frame of a crossing, since it only does anything the frame the board's
    /// tiled-ness actually flips — the same shape as `CanvasLinkNodeView`'s override. What it keeps in
    /// step is `engagement.isTiled`, so a project card's buttons stop waiting for the click that steps
    /// into it the moment there is nowhere left to step in *from*.
    override func refreshTiledness(fading: Bool) {
        super.refreshTiledness(fading: fading)
        let tiled = board.showsTiles
        guard engagement.isTiled != tiled else { return }
        engagement.isTiled = tiled
    }

    override func engagementChanged() {
        if document != nil || (isEngaged && writesInPlace) { return documentEngagementChanged() }
        engagement.isEngaged = isEngaged
        if isEngaged {
            // The keyboard has to reach the text fields inside. A hosting view takes it on behalf of
            // whatever SwiftUI has focused.
            if let content = subviews.first { window?.makeFirstResponder(content) }
        } else if let content = subviews.first,
                  (window?.firstResponder as? NSView)?.isDescendant(of: content) == true {
            window?.makeFirstResponder(board)
        }
    }

    /// Scrolled off the board: give the project's store back. The registry drops it when the last
    /// holder does, and a board of forty project cards would otherwise hold forty projects open for as
    /// long as the window lived.
    override func prepareForRemoval() {
        CanvasFileWatch.shared.stop(self)
        document?.flush()
        releaseProject()
        releaseFolder()
    }

    /// A folder under the one this card lists is gone into, in the card — see `CanvasFolderCard`.
    override func followsInPlace(_ url: URL) -> Bool {
        folder?.go(to: url) ?? false
    }

    private func releaseFolder() {
        folder?.stop()
        folder = nil
    }

    private func releaseProject() {
        projectEdits = nil
        if board.lastEditedProject === projectStore { board.lastEditedProject = nil }
        StoreRegistry.shared.release(projectStoreKey)
        projectStore = nil
        projectStoreKey = nil
    }

    private func missingView(_ path: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 4
        stack.alignment = .centerX

        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: "questionmark.square.dashed",
                              accessibilityDescription: nil)
        glyph.contentTintColor = .tertiaryLabelColor
        glyph.symbolConfiguration = .init(pointSize: 22, weight: .regular)

        let label = NSTextField(labelWithString: path)
        label.font = .systemFont(ofSize: 10.5)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = "Folio looked for this everywhere it knows to look and didn't find it."

        stack.addArrangedSubview(glyph)
        stack.addArrangedSubview(label)
        label.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -16).isActive = true
        return stack
    }

    /// The part of a note a `#Heading` subpath names: that heading and everything under it, stopping
    /// at the next heading of the same level or higher.
    ///
    /// Nil when the heading isn't there, so the card falls back to the whole note rather than to
    /// nothing — a renamed heading should cost you the framing, not the content.
    private func section(named subpath: String, in text: String) -> String? {
        let wanted = subpath.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }

        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { line in
            guard line.hasPrefix("#") else { return false }
            return line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare(wanted) == .orderedSame
        }) else { return nil }

        let level = lines[start].prefix(while: { $0 == "#" }).count
        var end = lines.index(after: start)
        while end < lines.endIndex {
            let line = lines[end]
            if line.hasPrefix("#") {
                let here = line.prefix(while: { $0 == "#" }).count
                if here <= level && line.dropFirst(here).first == " " { break }
            }
            end = lines.index(after: end)
        }
        return lines[start..<end].joined(separator: "\n")
    }

    // MARK: Writing in place

    /// The document you are writing in, while you are. See `CanvasDocSession`.
    private var document: CanvasDocSession?

    /// ⌘Z while you are writing here: the editor's own stack, as a typed card's is. File edits are the
    /// file's, not the board's, so there is no step for the board to take back afterwards either.
    private(set) var documentUndo: UndoManager?

    /// Where the caret was, for an editor rebuilt under you by a change of face or width.
    private var resumeAt: NSRange?

    /// Whether this card has an editor open on its file.
    var isWritingDocument: Bool { document != nil }

    private func documentEngagementChanged() {
        if isEngaged {
            guard let url = location.url else { return }
            let session = CanvasDocSession(url: url)
            session.onWrite = { [weak self] in
                guard let self else { return }
                CanvasFileWatch.shared.acknowledge(self)
            }
            document = session
            contentChanged()
            return
        }
        guard let session = document else { return }
        // What the editor says now, not what it last reported: SwiftUI hands a change on a turn later,
        // so the keystroke just before a click elsewhere hasn't reached the session yet — and the
        // session is about to stop listening.
        if let live = firstTextView?.string, live != session.text { session.changed(live) }
        document = nil
        documentUndo = nil
        resumeAt = nil
        session.flush()
        finish(session)
        contentChanged()
    }

    private func documentEditor(_ session: CanvasDocSession, url: URL) -> NSView {
        let undo = UndoManager()
        documentUndo = undo
        let view = NSHostingView(rootView:
            CanvasTextEditing(text: session.text, zoom: contentZoom, style: textStyle, startsAt: resumeAt,
                              noteURL: url, undoManager: undo) { [weak session] edited in
                session?.changed(edited)
            } onDone: { [weak self] in
                self?.engage(false)
            } onOpenProject: { folder in
                WindowManager.shared.open(named: folder)
            } onSelectionChange: { [weak self] range in
                self?.resumeAt = range
            })
        DispatchQueue.main.async { [weak self, weak view] in
            guard let view, self?.document != nil else { return }
            self?.window?.makeFirstResponder(view)
        }
        return view
    }

    /// What stepping out means for a card that was made before it had words: taken away with its file
    /// if it still has none, named after its first line if it does. See `CanvasDocCards`.
    private func finish(_ session: CanvasDocSession) {
        guard node.extra[CanvasDocCards.untitledKey] != nil else { return }
        let id = node.id
        func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if blank(session.text), blank(session.opening) {
            board.store.changeQuietly { doc in
                doc.nodes.removeAll { $0.id == id }
                doc.edges.removeAll { $0.fromNode == id || $0.toNode == id }
            }
            // Only a file that is still nothing — one this card made, with nothing in it to keep, which
            // is also why it isn't sent to the Trash: a Trash full of empty Untitleds is its own litter.
            if (try? Data(contentsOf: session.url))?.isEmpty == true {
                try? FileManager.default.removeItem(at: session.url)
            }
            return
        }
        guard session.url.pathExtension.lowercased() == "md",
              let title = CanvasDocCards.title(from: session.text) else { return }
        let folder = session.url.deletingLastPathComponent()
        let named = CanvasDocCards.available(title, in: folder, except: session.url)
        do {
            if named.standardizedFileURL != session.url.standardizedFileURL {
                try FileManager.default.moveItem(at: session.url, to: named)
            }
        } catch {
            Log.write("naming a card's file failed: \(error)")
            return
        }
        let path = board.store.resolver.storablePath(for: named) ?? named.path
        board.store.changeQuietly { doc in
            guard let index = doc.nodes.firstIndex(where: { $0.id == id }) else { return }
            doc.nodes[index].content = .file(path: path, subpath: nil)
            doc.nodes[index].extra[CanvasDocCards.untitledKey] = nil
        }
    }

    // MARK: Opening

    /// What "work on this card" means, which is not the same thing for every file.
    ///
    /// For nearly all of them it means opening the document, because PM does not edit pictures, PDFs or
    /// somebody's markdown — the card is a view of a file that belongs to another app. For a project it
    /// means the opposite: the card *is* the project, editable in place (see `CanvasProjectNote`), and
    /// handing it to Obsidian would be walking past the thing you clicked on to open its source.
    ///
    /// This is what a single click reaches on a project card, through `engagesOnClick` — so getting it
    /// wrong meant a click on a project launching Obsidian, which is the one place a click on it should
    /// never go.
    override func beginEditing() {
        if writesInPlace, !isSimplified { return engage(true) }
        guard isProjectCard else { return open() }
        // Too far out to read, let alone edit. "Open this" then means the project window, which is
        // where a project you cannot see on the board is actually usable — still the project, still
        // not Obsidian.
        guard !isSimplified else {
            board.goToProject(self)
            return
        }
        engage(true)
    }

    /// Open the file where it belongs: a note in Obsidian, anything else in whatever owns it. What the
    /// card's own menu item does, on any card including a project's.
    ///
    /// A note goes to Obsidian rather than to a text editor because that is where it is written, and
    /// the canvas it is on is an Obsidian document — jumping to a different app to read a note that
    /// lives in the vault would be PM asserting an ownership it doesn't have.
    func openInOwningApp() { open() }

    private func open() {
        guard let url = location.url else { return }
        if ["md", "markdown"].contains(url.pathExtension.lowercased()) {
            let config = (try? loadConfig()) ?? nil
            let heading = stored.subpath?.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            if let link = ObsidianLink.url(notesPath: url.path, config: config, heading: heading) {
                NSWorkspace.shared.open(link)
                return
            }
        }
        NSWorkspace.shared.open(url)
    }

    /// Write the corrected path back into the canvas — the repair the strip offers.
    func repairPath() {
        guard case .moved(let url, _) = location,
              let corrected = board.store.resolver.storablePath(for: url) else { return }
        let id = node.id
        board.store.change("Repair Card Path") { doc in
            guard let index = doc.nodes.firstIndex(where: { $0.id == id }),
                  case .file(_, let subpath) = doc.nodes[index].content else { return }
            doc.nodes[index].content = .file(path: corrected, subpath: subpath)
        }
    }
}

/// An HTML file from the vault, rendered as the web page it is.
///
/// Read access is the file's own folder, so a page finds the stylesheets, scripts and pictures beside
/// it and nothing above them. The store is not persistent: a page opened from disk has no business
/// sharing cookies or storage with the web cards' sessions (`CanvasWebSession`). A link to another
/// place leaves for the default browser rather than replacing the file the card is for.
final class CanvasHTMLFileView: WKWebView, WKNavigationDelegate {
    init(url: URL) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        super.init(frame: .zero, configuration: configuration)
        navigationDelegate = self
        setAccessibilityLabel(url.lastPathComponent)
        loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let target = action.request.url else {
            return decisionHandler(.allow)
        }
        // Same file, different fragment: an in-page anchor, which is still this card's page.
        if target.isFileURL, target.deletingFragment == webView.url?.deletingFragment {
            return decisionHandler(.allow)
        }
        NSWorkspace.shared.open(target)
        decisionHandler(.cancel)
    }
}

private extension URL {
    var deletingFragment: URL {
        var parts = URLComponents(url: self, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        return parts?.url ?? self
    }
}

/// One sitting of writing in a file card: what the file said when you started, what it says now, and
/// the write that puts the second on disk.
///
/// **Written shortly after you stop, and always on the way out.** Every keystroke to disk would be a
/// file event per character for Obsidian, iCloud and anything else watching the vault; a write only on
/// stepping out would lose a sitting to a crash. Half a second after the last change is neither.
@MainActor
final class CanvasDocSession {
    let url: URL
    /// What the file held when you stepped in — the half of "was this ever a card?" that
    /// `CanvasDocCards` needs besides what it holds now.
    let opening: String
    private(set) var text: String
    /// What the file holds as far as this session knows — what it read, or last wrote. The difference
    /// between this and `text` is typing not yet on disk.
    private(set) var synced: String
    private var pending: DispatchWorkItem?
    /// Called after each write, so the card's watch can take the write as its own. See
    /// `CanvasFileWatch.acknowledge`.
    var onWrite: (() -> Void)?

    init(url: URL) {
        self.url = url
        let read = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        opening = read
        text = read
        synced = read
    }

    var hasUnsavedEdits: Bool { text != synced }

    /// Take the file's version as this session's — something else changed it, and nothing here was
    /// waiting to be written.
    func adopt(_ disk: String) {
        pending?.cancel()
        pending = nil
        text = disk
        synced = disk
    }

    func changed(_ edited: String) {
        text = edited
        pending?.cancel()
        // The editor reporting back text that is already the file — an adopted change arriving through
        // the binding — is nothing to write.
        guard edited != synced else { pending = nil; return }
        let write = DispatchWorkItem { [weak self] in self?.flush() }
        pending = write
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: write)
    }

    /// Write now, if anything is waiting.
    func flush() {
        guard let write = pending else { return }
        write.cancel()
        pending = nil
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            synced = text
            onWrite?()
        } catch {
            Log.write("writing a card's file failed: \(error)")
        }
    }
}
