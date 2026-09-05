import AppKit
import SwiftUI
import PDFKit
import PmLib

/// A card showing a file from the vault: a note, a picture, a PDF.
///
/// **The card is the file's contents and nothing else.** It used to carry a header strip naming the
/// file, which was doing two jobs. Identifying the card is the smaller one, and the note's own first
/// heading usually does it better; what is left of it is on the tooltip, and zoomed out the filename
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

    override init(node: CanvasNode, board: CanvasBoardView, scale: Double) {
        super.init(node: node, board: board, scale: scale)
        contentChanged()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var stored: (path: String, subpath: String?) {
        if case .file(let path, let subpath) = node.content { return (path, subpath) }
        return ("", nil)
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
        if isSimplified, !isPicture(path) {
            setContent(summaryView(shortName(for: path), symbol: symbol(for: path)))
            return
        }

        setContent(preview(for: location, path: path, subpath: subpath))
    }

    /// What the card says about itself when you linger on it: which file, which heading, and whether
    /// PM had to go looking for it. See `CanvasNodeView.cardDescription`.
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

    /// What the card is called when the board is too far out to read it.
    ///
    /// A project's notes file is named for the project, so the `Notes - ` prefix is the one part of the
    /// filename that says nothing — and at this zoom the card is one line of text, which makes eight
    /// wasted characters a third of it. Every board of projects otherwise reads as a row of cards all
    /// starting with the same word.
    private func shortName(for path: String) -> String {
        let name = ((path as NSString).deletingPathExtension as NSString).lastPathComponent
        guard projectFolder(ofNotesPath: path) != nil, name.hasPrefix("Notes - ") else { return name }
        return String(name.dropFirst("Notes - ".count))
    }

    /// The project this card's file belongs to, if it is a project's notes. What the menu's Open
    /// Project acts on.
    var projectFolderName: String? {
        projectFolder(ofNotesPath: stored.path).map { ($0 as NSString).lastPathComponent }
    }

    private func isPicture(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]
            .contains((path as NSString).pathExtension.lowercased())
    }

    private func symbol(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown", "txt": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff": return "photo"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }

    /// The card's body: the file, drawn as the kind of thing it is.
    private func preview(for location: CanvasFileLocation, path: String, subpath: String?) -> NSView {
        guard let url = location.url else { return missingView(path) }

        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp":
            let image = NSImageView()
            image.imageScaling = .scaleProportionallyUpOrDown
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
                    CanvasProjectNote(store: store, engagement: engagement, noteURL: url) { folder in
                        WindowManager.shared.open(named: folder)
                    })
            }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let shown = subpath.flatMap { section(named: $0, in: text) } ?? text
            return NSHostingView(rootView:
                ScrollView(.vertical) {
                    RenderedNote(prose: shown,
                                 font: .systemFont(ofSize: 12.5),
                                 noteURL: url,
                                 maxImageHeight: 320)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDisabled(true))

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
        return store
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

    override func engagementChanged() {
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
        releaseProject()
    }

    private func releaseProject() {
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
        label.toolTip = "PM looked for this everywhere it knows to look and didn't find it."

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
        guard isProjectCard else { return open() }
        // Too far out to read, let alone edit. "Open this" then means the project window, which is
        // where a project you cannot see on the board is actually usable — still the project, still
        // not Obsidian.
        guard !isSimplified else {
            if let folder = projectFolderName { WindowManager.shared.open(named: folder) }
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
