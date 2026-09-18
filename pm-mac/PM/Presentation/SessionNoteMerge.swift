import Foundation

/// What to write when the note on disk is no longer what the open surface last agreed with.
///
/// The full-screen note surface can sit open over another application for as long as you leave it,
/// while a project window, an Obsidian tab or the CLI writes the same session note. A whole-region
/// replace would quietly throw that work away, so every write asks this first.
///
/// Pure, and separate from the controller, because it is the one piece of judgement in the write path
/// and the only piece worth testing on its own — everything around it is store plumbing.
enum SessionNoteMerge {
    enum Outcome: Equatable {
        /// Nothing to do: the file already says what the surface says.
        case unchanged
        /// The ordinary path — nobody else touched it, so the surface's text is the answer.
        case replace(String)
        /// Somebody else wrote, and the surface's text is still theirs-plus-our-additions, so the two
        /// can be put together without diffing: their new text, our additions after it.
        case merged(String)
        /// Somebody else wrote, and the surface has diverged from what it read — the additions can't be
        /// separated from the edits, so the surface's text wins and the caller says so.
        ///
        /// Last-write-wins, which is exactly the contract the project window's takeover already keeps.
        /// Not a new hazard; an old one reached from a new place.
        case overwrote(String)
    }

    /// - Parameters:
    ///   - edited: what the surface currently holds.
    ///   - onDisk: today's note — the session's whole body — as the store has it now.
    ///   - seed: what the surface last agreed with — read on opening, then whatever it last wrote.
    static func resolve(edited: String, onDisk: String, seed: String) -> Outcome {
        guard edited != onDisk else { return .unchanged }
        guard onDisk != seed else { return .replace(edited) }
        // The prefix test is deliberately exact rather than fuzzy. It answers one question — "is
        // everything this surface started with still untouched at the front of what it holds?" — and a
        // near-miss is a case where nobody can say which of the two edits to keep.
        guard edited.hasPrefix(seed) else { return .overwrote(edited) }
        let additions = String(edited.dropFirst(seed.count))
        guard !additions.isEmpty else { return .merged(onDisk) }
        return .merged(onDisk + separator(between: onDisk, and: additions) + additions)
    }

    /// What an open surface should now show, when the note on disk has moved underneath it — or nil to
    /// keep what it has.
    ///
    /// **Only a surface with nothing unsaved follows.** One that is still holding what it last wrote
    /// has no edit of its own to lose, so it takes the new text and agrees with it; the file is the
    /// truth and the surface was only showing it. One with unsaved typing keeps it, and the next save
    /// goes through `resolve`.
    ///
    /// Not following is how a note was lost. An undo made elsewhere put the file back to before a
    /// paragraph while the editor went on showing it. Left alone, the surface still agreed with its
    /// seed, so it wrote nothing on the way out — the paragraph was gone from the file while the
    /// screen said otherwise. And with any typing after it, `resolve` read the rolled-back file as
    /// somebody else's work, kept it, and kept only what had been typed since the last save.
    static func adopting(onDisk: String, edited: String, seed: String) -> String? {
        guard edited == seed, onDisk != seed else { return nil }
        return onDisk
    }

    /// The join between what they wrote and what we added.
    ///
    /// Usually nothing: our additions begin with the newlines we typed to leave their text behind, and
    /// adding more would open a gap that nobody asked for. The case that needs one is the note that had
    /// no prose when this surface opened — there our additions are the whole of what we hold and start
    /// with a word, so without this they'd be run straight onto the end of their sentence. A blank line,
    /// because that is how the file separates paragraphs everywhere else.
    private static func separator(between existing: String, and additions: String) -> String {
        guard !existing.isEmpty else { return "" }
        if existing.hasSuffix("\n") || additions.hasPrefix("\n") { return "" }
        return "\n\n"
    }
}
