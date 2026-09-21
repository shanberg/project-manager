import AppKit
import SwiftUI

/// The session pill: the name of the jar this card drinks from, at the head of the address bar.
///
/// **Drawn only when it isn't the shared one.** A badge on every card would be furniture — the same
/// argument the lock lost in `CanvasAddressField.mark`. The shared session is what nearly every card
/// has always used, so a pill that is always there says nothing on the one card where the answer
/// matters. `CanvasHeaderModel.Page.session` is nil for that case and this is never built.
///
/// **Private is coloured; a profile is not.** "Work" is a fact about which account you are signed in
/// as, and the name carries it. Private is a promise — nothing here is being written down, and it all
/// goes when Folio quits — and a promise you have forgotten about is one that gets broken. It is the
/// one state in this row, apart from an unencrypted page, allowed a colour of its own, and it is the
/// browsers' purple rather than the app's accent because the accent is whatever the user picked and
/// may be this pill's neighbour on the very next card.
///
/// A file of its own so it can be compiled alone and looked at — `CanvasSessionPillTests` renders it
/// and measures what a name does to the row. The address field it sits in reaches for half the app.
struct CanvasSessionPill: View {
    let name: String
    /// The ephemeral store rather than a profile you named. Resolved where the page model is built,
    /// so which name is the reserved one stays `CanvasWebSession`'s question.
    let isPrivate: Bool

    /// As many characters of a name as this row can spare. The address is what the bar is *for*, so a
    /// profile called something long is cut rather than allowed to eat it.
    ///
    /// Cut as a string rather than capped with `frame(maxWidth:)`, which is greedy in a row like this
    /// one: it claims the width it is allowed whether or not the word needs it, and "Work" would sit
    /// in the middle of a pill sized for a name nobody typed.
    static let longestName = 14

    static func shown(_ name: String) -> String {
        name.count <= longestName ? name : String(name.prefix(longestName - 1)) + "\u{2026}"
    }

    var body: some View {
        Text(Self.shown(name))
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            // Never stretched and never squeezed: the address beside it is the flexible half of the
            // row, and a pill that gave up points as a path got longer would be a label that changed
            // size while you read it.
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(tint)
            .background(Capsule(style: .continuous).fill(tint.opacity(0.16)))
            .help(Self.explanation(name: name, isPrivate: isPrivate))
            // The field's own label says this instead, in one sentence — two labels beside each other
            // is something the reader has to assemble.
            .accessibilityHidden(true)
    }

    private var tint: Color {
        isPrivate ? Color(nsColor: .systemPurple) : Color(nsColor: .secondaryLabelColor)
    }

    /// What the pill means, for its tooltip and the field's. Says what is true of the *storage*, which
    /// is the whole of what private means here: WebKit has no encrypted-at-rest option and PM does not
    /// pretend otherwise (see `CanvasWebSession`), so this promises forgetting and nothing more.
    static func explanation(name: String, isPrivate: Bool) -> String {
        isPrivate
            ? "Private session: signed in as nobody. Nothing this page stores is written to disk, and"
                + " it is gone when Folio quits."
            : "Signed in on the \(name) session, which this card keeps to itself."
    }
}
