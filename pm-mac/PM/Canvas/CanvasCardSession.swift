import Foundation
import PmLib

/// Which browser session a web card uses — the shared one, or a profile of its own.
///
/// **The second account is the whole reason this exists.** One jar for every card is right nearly all
/// the time and argued for at length in `CanvasWebSession`: signing in is something you do to a site,
/// and twelve cards on one tracker should not be twelve sign-ins. What it cannot express is work and
/// personal mail on one board, two tenants of one tool, a client's staging box beside your own. Those
/// are not one session, and a board that could only hold one of them at a time was a board you had to
/// sign out of to use.
///
/// **Kept on the node, in the file**, which is the `CanvasCardZoom` bargain and for the same reason:
/// this is something you *set*. A card that forgot which account it was for every time the window
/// closed would be worse than not offering the choice, and the profile is a name rather than a
/// credential — nothing secret is written to the canvas.
enum CanvasCardSession {
    /// The key PM writes. Prefixed, because a `.canvas` is a shared document.
    static let key = "pmSession"

    /// The profile this card uses, or nil for the shared session every card has always used.
    static func of(_ node: CanvasNode) -> String? {
        guard case .string(let name)? = node.extra[key] else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Put this card on a profile, or back on the shared session with nil.
    static func set(_ name: String?, on node: inout CanvasNode) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        // The shared session is written as the absence of the key rather than as a name, so a card put
        // on a profile and taken off it again leaves the file exactly as it found it.
        node.extra[key] = (trimmed?.isEmpty ?? true) ? nil : .string(trimmed!)
    }

    /// What the card's menu calls the session it is on.
    static func title(_ name: String?) -> String { name ?? "Shared" }
}
