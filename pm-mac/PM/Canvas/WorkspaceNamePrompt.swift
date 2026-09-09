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
