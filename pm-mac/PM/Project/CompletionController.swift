import AppKit
import PmLib

/// The `@` / `/` completion loop, independent of what's being typed into.
///
/// This exists because the loop has to work in more than one kind of field. The note editor is an
/// `NSTextView`; the task list's add/edit editors are `NSTextField`s; they share no superclass and
/// route keys through different mechanisms. What they *do* share is the whole of the interaction —
/// which sigil is active, what it offers, what the arrow keys mean, what Return inserts — so that
/// lives here once and each field contributes only its own two facts: the text, and the caret.
///
/// Nothing here touches a text storage. `handle` returns the text a caller should end up with and the
/// caller applies it however its own edits are applied — through `applyIfPossible` in the text view,
/// through the field editor in the text field. That's what keeps one undo story per surface instead of
/// this inventing a second one.
@MainActor
final class CompletionController {
    let popover = MentionPopover()
    var isVisible: Bool { popover.isVisible }

    /// A row, and what taking it does.
    private enum Completion {
        case mention(MentionCandidate)
        case command(EditorCommand)

        var item: MentionPopover.Item {
            switch self {
            case .mention(let c):
                // An archived project still matches — you do refer back to finished work — but it says
                // so, because waiting on one is released the moment it's written.
                //
                // The row is always written short, with the code in its own trailing column — which is
                // the column that goes away when the app has been told not to write codes. The title
                // stays put either way: this is a picker, and a row that changed width with a
                // preference would be a different list to aim at.
                let showsCode = ProjectCodes.areShown
                return .init(id: "@\(c.name)", title: c.shortName,
                             detail: showsCode && !c.code.isEmpty ? c.code : nil,
                             trailing: c.isArchived ? "archived" : nil)
            case .command(let c):
                return .init(id: "/\(c.id)", title: c.title, detail: c.detail, trailing: nil)
            }
        }
    }

    private var completions: [Completion] = []
    /// A sigil offset the reader dismissed. Per sigil rather than global: ⎋ means "not this one", and
    /// the next one typed should still offer help.
    private var dismissedAt: Int?
    /// A sigil offset whose mention list opens on an empty query.
    ///
    /// `@` normally needs a character first, because a bare one is the focus marker. That rule is about
    /// what somebody *typed*; when `/waiting` writes the sigil itself the picker is the point, so the
    /// command marks its own sigil exempt.
    private var forcedMentionAt: Int?

    /// Where the candidates come from. Injected so this can be exercised without the app's index.
    var candidates: () -> [MentionCandidate] = { ProjectIndex.shared.mentionCandidates }

    /// What a key did, and what the field should do about it.
    enum KeyResult: Equatable {
        /// Consumed; nothing to write.
        case handled
        /// Consumed; the field should end up with this text and selection.
        case apply(text: String, selection: Range<String.Index>)
        /// Not ours — the key means what it usually means.
        case ignored
    }

    /// Recompute what should be showing for this text and caret.
    ///
    /// - Parameter screenAnchor: the rect of a character range **in screen coordinates**, which is
    ///   what `firstRect(forCharacterRange:actualRange:)` returns. Supplied by the field because only
    ///   it knows where its own glyphs are.
    func refresh(text: String, caret: String.Index,
                 screenAnchor: (Range<String.Index>) -> NSRect, in view: NSView) {
        // Both sigils are scanned and the nearer one wins. `/task and @web` has an active `/` behind it
        // that would otherwise claim the mention being typed in front of it.
        let mention = completionQuery(in: text, caret: caret, sigil: "@", requiresCharacter: false)
        let command = commandQuery(in: text, caret: caret)
        let found = [mention, command].compactMap { $0 }
        guard let query = found.max(by: { $0.range.lowerBound < $1.range.lowerBound }) else {
            return dismissAll()
        }
        let sigil = text.distance(from: text.startIndex, to: query.range.lowerBound)
        if dismissedAt == sigil { return popover.hide() }
        dismissedAt = nil

        if query == mention {
            // The focus-marker rule, stated where the forcing exemption can see it.
            guard !query.query.isEmpty || forcedMentionAt == sigil else { return dismissAll() }
            let all = candidates()
            let ranked = query.query.isEmpty ? all : ProjectSearch.rank(all, query: query.query) {
                ProjectSearch.Candidate(name: $0.name, shortName: $0.shortName,
                                        code: $0.code, isArchived: $0.isArchived)
            }
            completions = ranked.map(Completion.mention)
        } else {
            forcedMentionAt = nil
            completions = rankEditorCommands(editorCommands(), query: query.query).map(Completion.command)
        }
        popover.show(completions.map(\.item), screenAnchor: screenAnchor(query.range), in: view)
    }

    /// What ↑ ↓ ⏎ ⇥ ⎋ mean while the list is up. `ignored` for everything else, and for every key when
    /// it isn't.
    func handle(keyCode: UInt16, text: String, caret: String.Index) -> KeyResult {
        guard isVisible else { return .ignored }
        switch keyCode {
        case 126: popover.move(by: -1); return .handled
        case 125: popover.move(by: 1); return .handled
        case 53:
            dismiss(text: text, caret: caret)
            return .handled
        case 36, 48:
            guard let index = popover.selectedIndex, completions.indices.contains(index) else {
                return .ignored
            }
            return accept(completions[index], text: text, caret: caret)
        default:
            return .ignored
        }
    }

    /// ⎋: take the list down, and remember which sigil it was so it stays down until the caret leaves.
    func dismiss(text: String, caret: String.Index) {
        let found = [completionQuery(in: text, caret: caret, sigil: "@", requiresCharacter: false),
                     commandQuery(in: text, caret: caret)].compactMap { $0 }
        if let nearest = found.max(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            dismissedAt = text.distance(from: text.startIndex, to: nearest.range.lowerBound)
        }
        forcedMentionAt = nil
        completions = []
        popover.hide()
    }

    func dismissAll() {
        dismissedAt = nil
        forcedMentionAt = nil
        completions = []
        popover.hide()
    }

    /// Take a row.
    ///
    /// A mention inserts the **full folder name**, not the title the row shows. The title is what
    /// reads; the folder name is what survives, because it carries the `CODE-NNN` a rename keeps.
    private func accept(_ completion: Completion, text: String, caret: String.Index) -> KeyResult {
        switch completion {
        case .mention(let candidate):
            guard let query = completionQuery(in: text, caret: caret, sigil: "@",
                                              requiresCharacter: false) else { return .ignored }
            let out = applyMention(text, range: query.range, target: candidate.name)
            popover.hide()
            completions = []
            forcedMentionAt = nil
            return .apply(text: out.text, selection: out.selection)

        case .command(let command):
            guard let query = commandQuery(in: text, caret: caret) else { return .ignored }
            let out = applyEditorCommand(command, to: text, removing: query.range)
            popover.hide()
            completions = []
            // `/waiting` has written the sigil and expects the picker on it; mark it exempt from the
            // focus-marker rule so the caller's next `refresh` puts the list up.
            forcedMentionAt = out.opensMention
                ? out.text.distance(from: out.text.startIndex, to: out.selection.lowerBound) - 1
                : nil
            return .apply(text: out.text, selection: out.selection)
        }
    }
}
