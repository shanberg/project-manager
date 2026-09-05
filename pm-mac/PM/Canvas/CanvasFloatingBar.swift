import AppKit
import PmLib

/// The little bar that appears above whatever is selected.
///
/// It holds the things you do *to a card* — recolour it, repair its path, delete it — as opposed to
/// the things you do to the board, which are in the toolbar. Floating over the selection rather than
/// docked in a sidebar because a canvas is a spatial document: your attention is on a particular card
/// in a particular place, and a panel at the edge of the window makes you leave it and come back.
///
/// It follows the selection through scrolling and zooming, and it flips below the selection when
/// there isn't room above — a bar that ran off the top of the window while you dragged a card up
/// there would be a bar you could never reach.
@MainActor
final class CanvasFloatingBar: NSVisualEffectView {
    private weak var scroll: CanvasScrollView?
    private let stack = NSStackView()
    private var swatches: [NSButton] = []
    private var repairButton: NSButton?

    /// How far above the selection the bar sits.
    private static let gap: CGFloat = 12

    init(scroll: CanvasScrollView) {
        self.scroll = scroll
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        shadow = NSShadow()
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        isHidden = true

        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        buildControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildControls() {
        // "No colour" first, then Obsidian's six in their own order — the order is the file's, so a
        // board recoloured in PM and reopened in Obsidian has the colours you picked.
        for index in 0...CanvasPalette.presets.count {
            let button = NSButton(frame: .zero)
            button.bezelStyle = .shadowlessSquare
            button.isBordered = false
            button.title = ""
            button.target = self
            button.action = #selector(pickColour(_:))
            button.tag = index
            button.image = swatchImage(index: index)
            button.setAccessibilityLabel(index == 0 ? "No colour" : "Colour \(index)")
            button.toolTip = index == 0 ? "No colour" : nil
            button.widthAnchor.constraint(equalToConstant: 20).isActive = true
            button.heightAnchor.constraint(equalToConstant: 20).isActive = true
            swatches.append(button)
            stack.addArrangedSubview(button)
        }

        stack.addArrangedSubview(divider())

        let repair = iconButton("arrow.triangle.branch", "Repair the stored path",
                                #selector(repairPaths))
        repair.isHidden = true
        repairButton = repair
        stack.addArrangedSubview(repair)

        stack.addArrangedSubview(iconButton("trash", "Delete", #selector(deleteSelection)))
    }

    private func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return line
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let button = NSButton(frame: .zero)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        button.contentTintColor = .labelColor
        button.toolTip = tip
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }

    private func swatchImage(index: Int) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        return NSImage(size: size, flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            if index == 0 {
                NSColor.tertiaryLabelColor.setStroke()
                circle.lineWidth = 1.4
                circle.stroke()
                // The slash that says "none" rather than "white".
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: rect.minX + 4, y: rect.maxY - 4))
                slash.line(to: NSPoint(x: rect.maxX - 4, y: rect.minY + 4))
                slash.lineWidth = 1.4
                slash.stroke()
            } else {
                CanvasPalette.presets[index - 1].setFill()
                circle.fill()
            }
            return true
        }
    }

    // MARK: Following the selection

    /// Show or hide the bar, and put it where the selection is.
    ///
    /// Positioned in the scroll view's own coordinates, converted from the board's — so it stays put
    /// relative to the cards through a scroll and a zoom, without being inside the magnified view,
    /// where it would be scaled along with the board and become unreadable at 20%.
    ///
    /// **Nothing at all in view mode.** A palette that flies out and parks itself next to whatever you
    /// clicked is the loudest thing on a board, and on a board you are reading it is answering a
    /// question nobody asked: selecting a card there is a step towards *using* it. Everything the bar
    /// offers is on the card's own contextual menu, and Delete is ⌫ — so in view mode a picked card
    /// says so with its shadow and nothing else appears, moves, or has to be dismissed.
    func follow(board: CanvasBoardView) {
        guard let scroll, board.mode == .edit,
              !board.selection.isEmpty, let bounds = board.selectionBounds else {
            isHidden = true
            return
        }
        layoutSubtreeIfNeeded()
        let size = fittingSize

        let inScroll = scroll.convert(bounds, from: board)
        var x = inScroll.midX - size.width / 2
        var y = inScroll.minY - size.height - Self.gap

        // Flipped below the selection when there isn't room above, and kept inside the window either
        // way — a card dragged to the top of the board must not take its controls off screen.
        if y < 4 { y = inScroll.maxY + Self.gap }
        y = min(max(4, y), scroll.bounds.height - size.height - 4)
        x = min(max(4, x), scroll.bounds.width - size.width - 4)

        frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        isHidden = false
        reflect(board: board)
    }

    /// Show what the selection currently is: which colour it has, and whether it can be repaired.
    private func reflect(board: CanvasBoardView) {
        let selected = board.selection.compactMap { board.document.node(id: $0) }
        let colours = Set(selected.map { $0.color ?? "" })
        let common = colours.count == 1 ? colours.first! : nil

        for (index, button) in swatches.enumerated() {
            let token = index == 0 ? "" : String(index)
            button.layer?.borderWidth = (common == token) ? 2 : 0
            button.layer?.borderColor = NSColor.controlAccentColor.cgColor
            button.layer?.cornerRadius = 10
        }

        repairButton?.isHidden = !selected.contains { node in
            guard case .file(let path, _) = node.content else { return false }
            return board.store.resolver.resolve(path).hasMoved
        }
    }

    // MARK: What the buttons do

    @objc private func pickColour(_ sender: NSButton) {
        guard let board = scroll?.board else { return }
        let token: String? = sender.tag == 0 ? nil : String(sender.tag)
        let ids = board.selection
        board.store.change("Change Colour") { doc in
            for index in doc.nodes.indices where ids.contains(doc.nodes[index].id) {
                doc.nodes[index].color = token
            }
            for index in doc.edges.indices where ids.contains(doc.edges[index].id) {
                doc.edges[index].color = token
            }
        }
    }

    @objc private func repairPaths() {
        guard let board = scroll?.board else { return }
        let ids = board.selection
        let resolver = board.store.resolver
        board.store.change("Repair Card Path") { doc in
            for index in doc.nodes.indices where ids.contains(doc.nodes[index].id) {
                guard case .file(let path, let subpath) = doc.nodes[index].content,
                      case .moved(let url, _) = resolver.resolve(path),
                      let corrected = resolver.storablePath(for: url) else { continue }
                doc.nodes[index].content = .file(path: corrected, subpath: subpath)
            }
        }
    }

    @objc private func deleteSelection() {
        scroll?.board.deleteSelection()
    }
}
