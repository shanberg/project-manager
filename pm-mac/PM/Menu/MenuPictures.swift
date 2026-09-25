import AppKit

/// Choice menus drawn rather than described.
///
/// A setting whose options differ in *shape* — how a canvas is arranged, how wide a line runs, which
/// face a note is set in, how a span of time is laid out — is a row of pictures (`NSMenu`'s palette
/// presentation). Each picture keeps its title, for VoiceOver and as its tooltip. Plain verbs stay
/// text, and so does anything read faster as words or numbers, such as a card's size.
///
/// The drawn glyphs are template images made in code, so they follow light, dark and the highlighted
/// row the way a symbol does.
@MainActor
enum MenuPictures {
    /// `items` as one row of pictures in the menu this item is added to.
    static func palette(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        menu.presentationStyle = .palette
        for item in items {
            item.toolTip = item.title
            menu.addItem(item)
        }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = menu
        return parent
    }

    static func symbol(_ name: String, _ label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)
    }

    // MARK: What each choice looks like

    static func layout(_ layout: CanvasViewSpec.Layout) -> NSImage? {
        switch layout {
        case .list: return symbol("list.bullet", layout.title)
        case .rail: return symbol("calendar.day.timeline.left", layout.title)
        case .week: return symbol("rectangle.split.3x1", layout.title)
        case .month: return symbol("calendar", layout.title)
        }
    }

    static func arrangement(_ arrangement: CanvasTiling.Arrangement) -> NSImage? {
        switch arrangement {
        case .grid: return symbol("square.grid.2x2", arrangement.title)
        case .masterStack: return symbol("rectangle.leadinghalf.inset.filled", arrangement.title)
        }
    }

    static func tabs(onSide: Bool) -> NSImage? {
        onSide ? symbol("rectangle.leftthird.inset.filled", "Tabs on the Side")
               : symbol("rectangle.topthird.inset.filled", "Tabs on Top")
    }

    /// Three lines of text, as long as the measure makes them, inside the card's edges.
    static func lineWidth(_ width: CanvasTextStyle.LineWidth) -> NSImage {
        let fraction: CGFloat
        switch width {
        case .narrow: fraction = 0.45
        case .readable: fraction = 0.65
        case .wide: fraction = 0.85
        case .full: fraction = 1
        }
        return drawn(width.title) { rect in
            let card = rect.insetBy(dx: 1, dy: 1)
            let outline = NSBezierPath(roundedRect: card, xRadius: 2, yRadius: 2)
            outline.lineWidth = 1
            outline.stroke()
            let inner = card.insetBy(dx: 2.5, dy: 3.5)
            let length = inner.width * fraction
            for row in 0..<3 {
                let y = inner.minY + CGFloat(row) * inner.height / 2
                // The last line of a paragraph runs short.
                let run = row == 0 ? length * 0.6 : length
                NSBezierPath.fill(NSRect(x: inner.midX - length / 2, y: y - 0.75, width: run, height: 1.5))
            }
        }
    }

    /// "Aa" in the face itself; Automatic is proportional over monospaced, as a card reads and edits.
    static func face(_ face: CanvasTextStyle.Face) -> NSImage {
        drawn(face.title) { rect in
            let size: CGFloat = 12
            let sans = NSFont.systemFont(ofSize: size, weight: .medium)
            let mono = NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
            let text: NSAttributedString
            switch face {
            case .proportional: text = NSAttributedString(string: "Aa", attributes: [.font: sans])
            case .monospaced: text = NSAttributedString(string: "Aa", attributes: [.font: mono])
            case .automatic:
                let mixed = NSMutableAttributedString(string: "A", attributes: [.font: sans])
                mixed.append(NSAttributedString(string: "a", attributes: [.font: mono]))
                text = mixed
            }
            let bounds = text.size()
            text.draw(at: NSPoint(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2))
        }
    }

    private static func drawn(_ label: String, _ draw: @escaping (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { rect in
            NSColor.black.set()
            draw(rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = label
        return image
    }
}
