import AppKit
import SwiftUI
import PDFKit
import PmLib

/// A card showing a file from the vault: a note, a picture, a PDF.
///
/// The header strip is the part Obsidian doesn't have, and it is here because PM knows something
/// Obsidian doesn't. A canvas stores a file's path from the vault root and never updates it, so when
/// PM archives or renumbers a project every card pointing into it goes stale — in a real vault, nearly
/// half of them had. `CanvasFileResolver` follows those to where the file actually went, and the strip
/// is where that gets said: the card shows the file, and says plainly that it isn't where the canvas
/// claims, with the repair one click away.
///
/// A card whose file is genuinely gone draws as missing **with the path it wanted**, rather than as an
/// empty rectangle. The path is the only clue to what was there.
@MainActor
final class CanvasFileNodeView: CanvasNodeView {
    private var location: CanvasFileLocation = .missing

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

        // Zoomed out, a note renders as a grey texture and a PDF page as a grey rectangle, and both
        // cost a full layout to produce. The filename is what you are actually reading at this size.
        // Pictures are the exception and keep rendering: an image is *more* legible small than any
        // text, and at this zoom it is usually the only thing on the board you can identify.
        if isSimplified, !isPicture(path) {
            let name = (path as NSString).deletingPathExtension as NSString
            setContent(summaryView(name.lastPathComponent, symbol: symbol(for: path)))
            return
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill

        let chip = CanvasCardChip(title: (path as NSString).lastPathComponent
                                    + (subpath.map { " · " + $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")) } ?? ""),
                                  symbol: symbol(for: path),
                                  warning: location.hasMoved ? movedNote : nil)
        stack.addArrangedSubview(chip)
        chip.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let body = preview(for: location, path: path, subpath: subpath)
        stack.addArrangedSubview(body)
        body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        setContent(stack)
    }

    /// What the strip says when PM had to go looking. Names the folder it landed in, because "moved"
    /// on its own doesn't tell you whether the project was archived or renamed.
    private var movedNote: String? {
        guard case .moved(let url, _) = location else { return nil }
        let parent = url.deletingLastPathComponent()
        let root = obsidianVaultRoot(for: url)
        let where_ = root.flatMap { CanvasFileResolver(canvas: url, vaultRoot: $0).storablePath(for: parent) }
        return "moved to " + (where_ ?? parent.lastPathComponent)
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

    override func beginEditing() { open() }

    /// Open the file where it belongs: a note in Obsidian, anything else in whatever owns it.
    ///
    /// A note goes to Obsidian rather than to a text editor because that is where it is written, and
    /// the canvas it is on is an Obsidian document — jumping to a different app to read a note that
    /// lives in the vault would be PM asserting an ownership it doesn't have.
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
