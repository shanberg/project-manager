import SwiftUI
import AppKit
import PmLib

/// How the wait on a task line reads: colour, weight, slant, and the glyph that trails the name.
///
/// A due date is drawn as a chip because a date has a frame of its own — it's a fact *about* the task,
/// pinned to the row's trailing edge where every row's date lines up. A wait isn't that shape. What a
/// task is waiting on is part of the sentence it makes ("send the launch email · Website Refresh"), so
/// it belongs in the run of text, and it wraps with the sentence rather than being laid out beside it.
///
/// Which leaves colour, weight, slant and one glyph to carry four states. They map cleanly:
///
/// | state | colour | type | glyph |
/// |---|---|---|---|
/// | waiting on something live | secondary | regular | clock |
/// | inherited from a waiting parent | tertiary | *italic* | clock |
/// | the thing waited on is archived | green | medium | check |
/// | names something PM can't place | tertiary | regular | none |
///
/// Italic does the work a dashed border does for an inherited due date. It's the only one of these
/// levers that reads as *reported* rather than as *less important*, which is the distinction: a
/// descendant isn't waiting a bit less, it's waiting because something above it said so.
///
/// The unresolvable case losing its glyph is deliberate too. `waiting: [[Dana]]` is a complete and
/// correct statement about a person, and a status marker on it would be claiming PM knows something
/// about Dana that it doesn't.
struct WaitRunStyle {
    var italic: Bool
    var symbol: String?

    /// The colour and weight the row draws with.
    ///
    /// AppKit rather than SwiftUI, because the row draws through a layout manager now — a pill is a
    /// rounded rect behind a run of glyphs, and SwiftUI has no way to say that. Kept as properties of
    /// the style rather than decided at the drawing site, so a state added here can't be given two
    /// different appearances by two callers.
    var color: NSColor
    var weight: NSFont.Weight

    init(resolution: WaitTarget, isOwn: Bool) {
        switch resolution {
        case .released:
            color = .systemGreen
            weight = .medium
            italic = false
            symbol = "checkmark"
        case .pending:
            color = isOwn ? .secondaryLabelColor : .tertiaryLabelColor
            weight = .regular
            italic = !isOwn
            symbol = "clock"
        case .unresolved:
            color = .tertiaryLabelColor
            weight = .regular
            italic = !isOwn
            symbol = nil
        }
    }
}

/// What a task is waiting on, as the row needs it: the name, what that name turns out to be, and
/// whether this task declared the wait or inherited it.
typealias TaskWait = (target: String, resolution: WaitTarget, isOwn: Bool)

/// The whole task line as one attributed string: the task text, then what it's waiting on.
///
/// One string rather than an `HStack`, because the wait is part of the sentence and has to wrap with
/// it — see the note on `WaitRunStyle`. Attributed rather than SwiftUI `Text`, because the tokens
/// inside it are drawn as pills by `TokenLayoutManager`, and a pill is a rounded rect behind a run of
/// glyphs, which SwiftUI has no way to say.
///
/// The task's own text goes secondary while it's waiting, and stays there — that recession is what
/// tells you at a glance which rows you can pick up. Not strikethrough: that means done, and a waiting
/// task is the opposite of done. A *released* wait puts the text back to primary, because the thing
/// blocking it has landed and the work is live again.
@MainActor
func taskLineAttributed(_ todo: Todo, wait: TaskWait?, size: CGFloat = 13) -> NSAttributedString {
    let held = wait.map { !$0.resolution.isReleased } ?? false
    let weight: NSFont.Weight = todo.isFocused ? .semibold : .regular
    let body = NSFont.systemFont(ofSize: size, weight: weight)

    var base: [NSAttributedString.Key: Any] = [
        .font: body,
        .foregroundColor: (todo.checked || held) ? NSColor.secondaryLabelColor : NSColor.labelColor,
    ]
    if todo.checked { base[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }

    // The text as written, tokens and all: the layout manager needs the brackets present to turn them
    // into the pill's padding, so nothing is stripped here.
    let out = NSMutableAttributedString(string: todo.text, attributes: base)

    guard let wait else { return out }
    let style = WaitRunStyle(resolution: wait.resolution, isOwn: wait.isOwn)
    out.append(NSAttributedString(string: "  ·  ", attributes: [
        .font: body, .foregroundColor: NSColor.tertiaryLabelColor,
    ]))
    var nameAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: style.weight),
        .foregroundColor: style.color,
    ]
    if style.italic {
        nameAttributes[.font] = NSFontManager.shared.convert(
            NSFont.systemFont(ofSize: size, weight: style.weight), toHaveTrait: .italicFontMask)
    }
    // The name it goes by now, not the name it was written under — see `waitDisplayName`. A project
    // renamed after this token was stored still draws its current title here, so the rename is
    // invisible rather than merely survivable.
    out.append(NSAttributedString(string: waitDisplayName(target: wait.target, resolution: wait.resolution),
                                  attributes: nameAttributes))
    if let symbol = style.symbol,
       let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size * 0.85, weight: style.weight)) {
        let attachment = NSTextAttachment()
        attachment.image = image.tinted(style.color)
        // On the baseline, optically centred against cap height. An attachment's default bounds sit
        // its *bottom* on the baseline, which hangs a symbol above the text it belongs to and is what
        // made the glyph and the words look like two different lines.
        let glyph = image.size
        attachment.bounds = CGRect(x: 0, y: (body.capHeight - glyph.height) / 2,
                                   width: glyph.width, height: glyph.height)
        out.append(NSAttributedString(string: "\u{2009}"))
        out.append(NSAttributedString(attachment: attachment))
    }
    return out
}

private extension NSImage {
    /// A template symbol drawn in one colour, since a text attachment carries no foreground style.
    func tinted(_ color: NSColor) -> NSImage {
        let out = NSImage(size: size, flipped: false) { rect in
            color.set()
            self.draw(in: rect)
            rect.fill(using: .sourceAtop)
            return true
        }
        out.isTemplate = false
        return out
    }
}
