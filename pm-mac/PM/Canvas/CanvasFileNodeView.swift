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
    /// Wakes a note that drew as prose because the project scan hadn't landed yet.
    private var indexWatch: ObservationRelay?
    private var lastUndoDepth = 0
    /// The listing this card shows when its path is a folder, watched while the card is up. See
    /// `CanvasFolderCard`.
    private var folder: CanvasFolderModel?
    /// The folder this card lists, when it is a folder card — what a file drop is filed into.
    var folderModel: CanvasFolderModel? { folder }
    /// What draws the folder: the Finder's list or icons, kept across rebuilds of the card's content so
    /// the selection and what is opened survive a zoom past reading and back.
    private(set) var folderBrowser: CanvasFolderBrowser?
    /// The file's bytes as last read, with its modification date then — what a picture, a PDF or prose
    /// is drawn from. Read off main by `contents(of:)`, since cards are built during the launch
    /// restore and a stalled cloud provider holds a read indefinitely.
    private var loaded: (url: URL, stamp: Date?, data: Data?)?
    /// The file a read is out for, so a rebuild meanwhile doesn't ask again.
    private var loading: URL?
    /// A picture card's view, kept across rebuilds so an animation doesn't restart on every one.
    private var pictureView: CanvasPictureView?
    /// A PDF card's document as last parsed, and the file it is out for. See `pdfDocument(of:)`.
    private var pdf: (url: URL, stamp: Date?, document: PDFBox)?
    private var pdfLoading: URL?

    override init(node: CanvasNode, board: CanvasBoardView, scale: Double) {
        super.init(node: node, board: board, scale: scale)
        contentChanged()
        // Whether a note is a project card turns on `ProjectIndex.waitRoots`, which a background scan
        // fills in. A card built before the scan lands (launch, workspace restore) resolves no project
        // and draws its file as prose, and nothing else would ask it to look again.
        //
        // Only a *newly resolvable* project rebuilds. A scan that comes back empty must not flip a card
        // that is already formatted back to prose.
        indexWatch = ObservationRelay(tracking: { _ = ProjectIndex.shared.waitRoots }) { [weak self] in
            guard let self, projectStore == nil,
                  let url = location.url,
                  CanvasProjectSource.projectKey(for: url) != nil else { return }
            contentChanged()
        }
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
        let width = textStyle.lineWidth
        if projectDisplay.lineWidth != width { projectDisplay.lineWidth = width }
        let options = CanvasFolderOptions.of(node)
        if let folder, folder.options != options {
            if let folderBrowser { folderBrowser.apply(options) } else { folder.options = options }
        }
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
        // A write of this session's own still out: the change is probably it, and its landing
        // acknowledges the new stamp.
        guard !session.isWriting else { return }
        BackgroundFileRead.read(session.url) { [weak self, weak session] data in
            guard let self, let session, document === session, !session.isWriting,
                  let disk = data.flatMap({ String(data: $0, encoding: .utf8) }),
                  disk != session.synced else { return }
            guard !session.hasUnsavedEdits else {
                Log.write("\(session.url.lastPathComponent) changed on disk while it had unsaved typing; keeping the typing")
                return
            }
            session.adopt(disk)
            // Into the editor as an edit it knows about, so ⌘Z still lines up — see `replaceFromOutside`.
            (firstTextView as? ShortcutTextView)?.replaceFromOutside(disk)
        }
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

    /// A project card's notes open at its line width. Its size and face are the task list's.
    override var setsLineWidth: Bool { setsProse || isProjectCard }

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
            if let folderBrowser, folderBrowser.model === model { return folderBrowser }
            let browser = CanvasFolderBrowser(model: model, linkZones: linkZones)
            browser.host = self
            folderBrowser = browser
            return browser
        }

        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp":
            // Fitted, or filling the card when the card is nearly the picture's own shape — which is
            // what keeps a board of photographs from being a board of grey margins. See
            // `CanvasPictureView`, which owns that judgement and the reason it is not a setting.
            // Read and decoded off main — see `PictureStore`. The card is built again when it lands.
            let lookup = PictureStore.shared.picture(at: url, owner: self) { [weak self] in
                guard let self, location.url == url else { return }
                contentChanged()
            }
            if case .inCloud = lookup { return cloudOnlyView(url) }
            let image = pictureView ?? CanvasPictureView()
            pictureView = image
            image.picture = lookup.picture
            image.setAccessibilityLabel(url.lastPathComponent)
            return image

        case "pdf":
            // A PDF card is a *preview*, so the view is stripped of everything that would invite
            // interaction it isn't going to get: one page, scaled to the card, no scrolling, no
            // shadow. Opening it properly is what the strip's button is for.
            if CloudFile.isCloudOnly(url) { return cloudOnlyView(url) }
            guard let read = pdfDocument(of: url) else { return NSView() }
            let view = PDFView()
            view.document = read
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
            if CloudFile.isCloudOnly(url) { return cloudOnlyView(url, downloading: opening == url) }
            guard let read = contents(of: url) else { return NSView() }
            let text = read.flatMap { String(data: $0, encoding: .utf8) } ?? ""
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
        if document != nil || opening != nil || (isEngaged && writesInPlace) { return documentEngagementChanged() }
        engagement.isEngaged = isEngaged
        if isEngaged, let folderBrowser {
            folderBrowser.focus()
        } else if isEngaged {
            // The keyboard has to reach the text fields inside. A hosting view takes it on behalf of
            // whatever SwiftUI has focused.
            if let content = cardContent { contentWindow?.makeFirstResponder(content) }
        } else if let content = cardContent,
                  (contentWindow?.firstResponder as? NSView)?.isDescendant(of: content) == true {
            giveUpFocus()
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
        folderBrowser?.teardown()
        folderBrowser = nil
        folder?.stop()
        folder = nil
    }

    /// The list and the path bar take their own clicks, stepped in or not — see `CanvasFolderBrowser`.
    override func takesClick(at local: NSPoint) -> Bool {
        guard let folderBrowser, folderBrowser.isDescendant(of: self) else { return false }
        return folderBrowser.takesClick(at: folderBrowser.convert(local, from: self))
    }

    /// The folder row or icon under `point`, in the superview's coordinates — where files dropped
    /// there would be filed. See `CanvasBoardView.folderTarget`.
    func folderRow(at point: NSPoint) -> URL? {
        guard let folderBrowser, folderBrowser.isDescendant(of: self), !isSimplified else { return nil }
        return folderBrowser.folderRow(at: folderBrowser.convert(point, from: superview))
    }

    private func releaseProject() {
        projectEdits = nil
        if board.lastEditedProject === projectStore { board.lastEditedProject = nil }
        StoreRegistry.shared.release(projectStoreKey)
        projectStore = nil
        projectStoreKey = nil
    }

    /// The bytes of `url`. Nil until the first read lands, which rebuilds the card; a file changed since
    /// its last read is read again and drawn as it was meanwhile. The inner nil is a file that couldn't
    /// be read.
    /// With `reading` false, only what is already read and current — nothing is asked for.
    private func contents(of url: URL, reading: Bool = true) -> Data?? {
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let had = loaded.flatMap { $0.url == url ? Optional($0.data) : nil }
        if let loaded, loaded.url == url, loaded.stamp == stamp { return .some(loaded.data) }
        guard reading else { return nil }
        guard loading != url else { return had }
        loading = url
        BackgroundFileRead.read(url) { [weak self] data in
            guard let self, loading == url else { return }
            loading = nil
            loaded = (url, stamp, data)
            contentChanged()
        }
        return had
    }

    /// The PDF at `url`, read *and parsed* off main — a large or broken PDF parses as slowly as it likes
    /// there. Nil until it lands, which rebuilds the card; the inner nil is a file that isn't one.
    private func pdfDocument(of url: URL) -> PDFDocument?? {
        let stamp = CanvasFileQueue.modified(url)
        if let pdf, pdf.url == url, pdf.stamp == stamp { return .some(pdf.document.document) }
        guard pdfLoading != url else { return pdf.flatMap { $0.url == url ? .some($0.document.document) : nil } }
        pdfLoading = url
        let reader = BackgroundFileRead.reader
        PictureStore.queue.async {
            let parsed = PDFBox(document: reader(url).flatMap(PDFDocument.init(data:)))
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, pdfLoading == url else { return }
                    pdfLoading = nil
                    pdf = (url, stamp, parsed)
                    contentChanged()
                }
            }
        }
        return pdf.flatMap { $0.url == url ? .some($0.document.document) : nil }
    }

    /// A file that is in the cloud and not on this Mac. Not read: reading downloads it, and a card
    /// coming into view isn't asking for that. Opening it is.
    private func cloudOnlyView(_ url: URL, downloading: Bool = false) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 4
        stack.alignment = .centerX

        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: nil)
        glyph.contentTintColor = .tertiaryLabelColor
        glyph.symbolConfiguration = .init(pointSize: 22, weight: .regular)

        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = .systemFont(ofSize: 11)
        name.textColor = .secondaryLabelColor
        name.alignment = .center
        name.lineBreakMode = .byTruncatingMiddle

        let note = NSTextField(labelWithString: downloading ? "Downloading…"
                                                            : "Online only. Downloads when you open it.")
        note.font = .systemFont(ofSize: 10.5)
        note.textColor = .tertiaryLabelColor
        note.alignment = .center

        for view in [glyph, name, note] { stack.addArrangedSubview(view) }
        name.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -16).isActive = true
        stack.setAccessibilityLabel("\(url.lastPathComponent), online only")
        return stack
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

    /// The file an editor is waiting on: stepped into, its bytes not read yet. Read off main, since a
    /// file only in the cloud downloads as it is read and a stalled provider holds that read.
    private var opening: URL?

    private func documentEngagementChanged() {
        if isEngaged {
            guard document == nil, let url = location.url else { return }
            // Already read and unchanged since: the editor opens at once.
            if let read = contents(of: url, reading: false), let data = read,
               let text = String(data: data, encoding: .utf8) {
                return startWriting(url, text)
            }
            guard opening != url else { return }
            opening = url
            contentChanged()
            BackgroundFileRead.read(url) { [weak self] data in
                guard let self, opening == url else { return }
                opening = nil
                guard isEngaged, location.url == url else { return contentChanged() }
                // Unreadable — a download that failed, say. Not an empty editor, whose first write
                // would put nothing over the file.
                guard let data, let text = String(data: data, encoding: .utf8) else {
                    Log.write("\(url.lastPathComponent) couldn't be read to write in")
                    NSSound.beep()
                    contentChanged()
                    return engage(false)
                }
                startWriting(url, text)
            }
            return
        }
        if opening != nil {
            opening = nil
            contentChanged()
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

    private func startWriting(_ url: URL, _ text: String) {
        let session = CanvasDocSession(url: url, text: text)
        session.onWrite = { [weak self] in
            guard let self else { return }
            CanvasFileWatch.shared.acknowledge(self)
        }
        document = session
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
            self?.contentWindow?.makeFirstResponder(view)
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
            // On the file's write queue, after the writes, and off main.
            let url = session.url
            session.afterWrites {
                if CloudFile.isEmptyFile(url) { try FileManager.default.removeItem(at: url) }
            }
            return
        }
        guard session.url.pathExtension.lowercased() == "md",
              let title = CanvasDocCards.title(from: session.text) else { return }
        let folder = session.url.deletingLastPathComponent()
        let named = CanvasDocCards.available(title, in: folder, except: session.url)
        let url = session.url
        let moves = named.standardizedFileURL != url.standardizedFileURL
        // The rename waits for the writes, on the file's queue, so it never overtakes the last one.
        session.afterWrites({
            if moves { try FileManager.default.moveItem(at: url, to: named) }
        }) { [weak self] failure in
            guard let self else { return }
            if let failure { return Log.write("naming a card's file failed: \(failure)") }
            if moves { board.createdFileMoved(from: url, to: named) }
            let path = board.store.resolver.storablePath(for: named) ?? named.path
            board.store.changeQuietly { doc in
                guard let index = doc.nodes.firstIndex(where: { $0.id == id }) else { return }
                doc.nodes[index].content = .file(path: path, subpath: nil)
                doc.nodes[index].extra[CanvasDocCards.untitledKey] = nil
            }
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

extension CanvasFileNodeView: CanvasFolderBrowserHost {
    func folderBrowser(_ browser: CanvasFolderBrowser, commit options: CanvasFolderOptions, actionName: String) {
        board.setFolderOptions(of: [node.id], actionName) { $0 = options }
    }

    /// Working in a folder card's list makes it the card the board is about — its ring, its header,
    /// what ⌘J and the menus act on — without taking the keyboard back from the list.
    func folderBrowserTookFocus(_ browser: CanvasFolderBrowser) {
        if board.selection != [node.id] { board.selection = [node.id] }
    }

    func folderBrowserStepOut(_ browser: CanvasFolderBrowser) {
        window?.makeFirstResponder(board)
    }

    func folderBrowser(_ browser: CanvasFolderBrowser, addCardsFor urls: [URL]) {
        board.addFileCards(urls, beside: node.id)
    }
}

/// A parsed PDF handed from the queue that parsed it to main, which is the only side that uses it.
private struct PDFBox: @unchecked Sendable {
    let document: PDFDocument?
}
