import SwiftUI

/// The type scale the sidebar and the project card draw their words in: four sizes — 17, 14, 13, 11 —
/// and every role below is one of them.
///
/// Hierarchy is said with weight and colour, never with another size. A label that wants to be quieter
/// goes secondary or tertiary; one that wants to be louder goes semibold. The half-point sizes this
/// replaced (11.5, 12, 12.5) were each a heading trying to sit between two roles, and together they
/// read as a page set by several hands — Reeder's lists get their polish from having three sizes and
/// holding to them.
///
/// Glyph sizes aren't in here: an SF Symbol's point size is an icon's footprint, not a role in the text.
enum FolioType {
    /// A card's name.
    static let title = Font.system(size: 17, weight: .semibold)
    /// The brief's opening line — the summary, in the brief's serif.
    static let lede = Font.system(size: 14, design: .serif)
    /// Rows, tasks, links: the words the lists are made of.
    static let body = Font.system(size: bodySize)
    /// Body, stressed: the window's own project in the sidebar, an Up Next card, a sitting's day.
    static let bodyEmphasis = Font.system(size: bodySize, weight: .semibold)
    /// The brief's copy, in serif so the project's standing content reads as a different medium from
    /// the task UI around it.
    static let reading = Font.system(size: bodySize, design: .serif)
    /// A section heading — "Up next", "Goals", "Still open". Sentence case, secondary, and heavier than
    /// the metadata it shares a size with.
    static let label = Font.system(size: metaSize, weight: .semibold)
    /// What trails or sits under a row: dates, counts, a site's name, the next task.
    static let meta = Font.system(size: metaSize)

    static let bodySize: CGFloat = 13
    static let metaSize: CGFloat = 11
}
