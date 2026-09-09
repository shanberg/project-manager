import AppKit

/// The one field a workspace needs, in an alert.
///
/// **Its own file because two objects ask for it and neither owns the other.** The board asks when you
/// name or duplicate the workspace it is showing; the window asks when the same commands are used on a
/// chip in the tab bar — including a chip for a board that is not on screen and has no pane to ask
/// through (docs/canvas-workspaces.md §7c).
///
/// Named on the way in rather than kept anonymously and named after: the name is the whole of a
/// workspace's identity, so there is no version of this that can be deferred.
///
/// **The two confirmations live here as well**, because they are the same subject asked about from the
/// same three places, and because both are the answer to the same fact: a workspace has no undo. A
/// tiling is view state, so `store.change` is not involved and ⌘Z reaches nothing — which is survivable
/// while every act is additive and is not survivable for the two that are not.
@MainActor
enum WorkspaceNamePrompt {
    /// Nil for cancel, and nil for a name that is only whitespace — an empty name is a cancel that
    /// went through the motions.
    static func run(titled title: String, seed: String) -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = seed
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Kept for this board, so a tab can open straight into it."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// **A name that is taken belongs to a workspace you are not looking at.**
    ///
    /// `CanvasWorkspaces.save` replaces, deliberately — that is what keeps a named workspace live, so
    /// that dragging a tile lands on it without a Save. But the same call is how a name is *acquired*,
    /// and there the thing being replaced is somebody else's six tiles. Typing "Dashboard" into the
    /// chip of an untitled workspace should not be able to silently end last week's Dashboard.
    ///
    /// The Finder's question, in the Finder's words, because it is the Finder's situation: one name,
    /// two things, and only one of them can keep it. Cancel is the default — the ordinary reason to be
    /// here is a name you did not know was taken.
    static func confirmReplacing(_ name: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "A workspace named “\(name)” already exists."
        alert.informativeText = "Replacing it keeps its name and forgets its tiles. This cannot be undone."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// **Delete is the one act on a workspace that takes something away.**
    ///
    /// Every other verb here is additive or reversible: naming promotes, renaming re-keys, duplicating
    /// copies, and closing a chip leaves the workspace exactly where it was. This forgets a list of
    /// cards and their widths with nothing to get them back from — and it sits two lines above "Close
    /// Tab" in the same menu, which is the harmless one. The alert is what tells them apart.
    ///
    /// Said in terms of what survives, because the fear the word "delete" raises here is about the
    /// cards, and the cards are fine.
    static func confirmDelete(_ name: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete the workspace “\(name)”?"
        alert.informativeText = """
            Its cards stay on the board and the tiles stay on screen. The workspace and its name are \
            forgotten, and this cannot be undone.
            """
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The name a workspace is born with, when nobody was asked for one.
    ///
    /// **Because ⌘Return does not stop to ask.** Every workspace has a name (docs/canvas-workspaces.md
    /// §7i), and the gesture that makes most of them is the board's fastest — fullscreen this card,
    /// tile those six. A modal in front of that would be a modal in front of looking at something. So
    /// the name is assigned and the chip is renameable in place the moment it appears, which is the
    /// Finder's bargain over an untitled folder: it has a real name from the start, and the real name
    /// is the thing you type over.
    ///
    /// Counted rather than described. "Grid, 6" was the seed the alert used, and it is the wrong thing
    /// to *be* called: it goes stale the moment you swap the arrangement or add a tile, and it puts a
    /// count on a chip, which is the one thing a chip has repeatedly been told not to carry.
    nonisolated static func freshName(avoiding taken: [String]) -> String {
        let base = "Workspace"
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// What Duplicate starts its field with. "Dashboard copy", then "Dashboard copy 2" — the Finder's
    /// rule, so a second duplicate does not offer a name that is already taken.
    /// `nonisolated` because it is string arithmetic and nothing else — the alert is the part that
    /// needs the main actor, and this is the part worth testing without one.
    nonisolated static func copyName(of name: String, avoiding taken: [String]) -> String {
        let base = "\(name) copy"
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
