import Foundation

/// The things you can put on a canvas, named once.
///
/// They were declared twice: "New Card / New Frame / New Link… / New File…" in the board's right-click
/// menu, and "Card / Frame / Link… / File…" in the header's `+`. That is the drift `PMCommand` exists
/// to prevent, arrived on the canvas — two menus a few hundred points apart on screen, offering the
/// same four commands under different names, with nothing but attention keeping them in step.
///
/// The full name wins over the bare noun. "Card" is a noun in a list of nouns, which reads as a
/// *kind* rather than an act; "New Card" is a command, which is what a menu item is. It also has to
/// hold its own in the board menu, where it sits above Cut, Paste and Delete — every one of them a
/// verb.
///
/// Only the names live here. Where a new card lands and what makes it are the board's business and
/// differ by surface: the board menu puts one where you right-clicked, the header's `+` puts one in
/// the middle of what you can see. What was drifting was the wording, not the placement.
enum CanvasAddCommand {
    case card, frame, link, file
    /// The project's own note — offered only by a board that is a project's and hasn't got it. See
    /// `CanvasProjectNoteCard`, which owns the question of when.
    case projectNote

    /// Ellipses follow the app's convention — a command that opens something further to finish the job
    /// takes one. A card and a frame appear ready to type in; a link and a file have to ask which.
    var title: String {
        switch self {
        case .card: return "New Card"
        case .frame: return "New Frame"
        case .link: return "New Link\u{2026}"
        case .file: return "New File\u{2026}"
        // No ellipsis: there is nothing to ask. The board already knows which document this is — that
        // is the whole difference between it and New File….
        case .projectNote: return "New Project Note"
        }
    }
}
