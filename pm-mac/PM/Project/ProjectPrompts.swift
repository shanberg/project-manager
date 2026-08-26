import AppKit
import PmLib

/// The two project commands that need something typed before they can run: creating one and renaming
/// one.
///
/// `NSAlert` with an accessory view rather than a sheet, because both have to work with no window open
/// — they're on the menu bar item's menu, and PM keeps running with every window closed. A sheet needs
/// a window to hang from; this doesn't.
@MainActor
enum ProjectPrompts {
    // MARK: New project

    static func newProject(then open: @escaping (String) -> Void) {
        guard let config = (try? loadConfig()) ?? nil, !config.domains.isEmpty else {
            ProjectLifecycle.present(PmError.configNotFound, doing: "Can't create a project")
            return
        }
        let codes = config.domains.keys.sorted()

        let domainPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        for code in codes {
            domainPicker.addItem(withTitle: "\(code) — \(config.domains[code] ?? code)")
            domainPicker.lastItem?.representedObject = code
        }
        // Reopen on the domain last used, which is nearly always the one wanted again.
        if let remembered = UserDefaults.standard.string(forKey: lastDomainKey),
           let index = codes.firstIndex(of: remembered) {
            domainPicker.selectItem(at: index)
        }

        let titleField = NSTextField(string: "")
        titleField.placeholderString = "Project title"

        let alert = NSAlert()
        alert.messageText = "New Project"
        alert.informativeText = "The number is assigned for you, following the domain's existing projects."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = stack([domainPicker, titleField])
        alert.window.initialFirstResponder = titleField

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let code = domainPicker.selectedItem?.representedObject as? String else { return }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        UserDefaults.standard.set(code, forKey: lastDomainKey)
        do {
            open(try ProjectLifecycle.create(domainCode: code, title: title))
        } catch {
            ProjectLifecycle.present(error, doing: "Couldn't create “\(title)”")
        }
    }

    // MARK: New area

    /// An area has no domain and no number, so the prompt is one field. Kept beside `newProject`
    /// rather than folded into it with a kind picker: the two prompts don't ask the same questions,
    /// and a picker that empties the row beneath it whenever you change it is a worse dialog than two.
    static func newArea(then open: @escaping (String) -> Void) {
        let titleField = NSTextField(string: "")
        titleField.placeholderString = "Area name"

        let alert = NSAlert()
        alert.messageText = "New Area"
        alert.informativeText = "Something ongoing — a responsibility you hold, a meeting that recurs. "
            + "It isn't numbered and it doesn't finish."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = stack([titleField])
        alert.window.initialFirstResponder = titleField

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        do {
            open(try ProjectLifecycle.create(kind: .area, title: title))
        } catch {
            ProjectLifecycle.present(error, doing: "Couldn't create “\(title)”")
        }
    }

    // MARK: Adopting a folder

    /// Take on a folder that's already in the areas root.
    ///
    /// A picker rather than a text field: the answer is always one of a known, usually short list, and
    /// typing a folder name you can't see is how you find out it was spelled differently. Nothing to
    /// take on is a message, not an empty menu — an empty picker reads as a broken command.
    static func adoptArea(then open: @escaping (String) -> Void) {
        let candidates: [String]
        let areasPath: String
        do {
            let (_, paths) = try loadConfigAndPaths()
            areasPath = paths.areasPath
            candidates = try getAdoptableFolders(basePath: areasPath)
        } catch {
            ProjectLifecycle.present(error, doing: "Can't look for folders to take on")
            return
        }

        guard !candidates.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Nothing to Take On"
            alert.informativeText = "Every folder in \(areasPath) is already an area. "
                + "A folder there with no notes in it is one PM could adopt."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }

        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        for folder in candidates {
            picker.addItem(withTitle: folder)
            picker.lastItem?.representedObject = folder
        }

        let alert = NSAlert()
        alert.messageText = "Take On a Folder as an Area"
        alert.informativeText = "PM writes a notes file into the folder and changes nothing else — "
            + "what's already in it stays where it is."
        alert.addButton(withTitle: "Take On")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = stack([picker])

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              let folder = picker.selectedItem?.representedObject as? String else { return }

        do {
            open(try ProjectLifecycle.adopt(folderNamed: folder))
        } catch {
            ProjectLifecycle.present(error, doing: "Couldn't take on “\(folder)”")
        }
    }

    // MARK: Rename

    /// Takes the folder name rather than a sidebar row, so the menu bar item — which only ever has a
    /// store — can offer the same command.
    static func rename(projectNamed name: String, isArchived: Bool) {
        let config = (try? loadConfig()) ?? nil
        let parts = try? parseProjectPrefixAndTitle(folderName: name,
                                                    domainCodes: Array(config?.domains.keys ?? [:].keys))
        let currentTitle = parts?.title ?? name

        let field = NSTextField(string: currentTitle)
        field.placeholderString = "Project title"

        let alert = NSAlert()
        alert.messageText = "Rename Project"
        // Say what *won't* change: the folder keeps its code and number, and only the title moves.
        alert.informativeText = parts.map { "“\($0.prefix)” stays the same — only the title changes." }
            ?? "The domain and number stay the same — only the title changes."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = stack([field])
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != currentTitle else { return }

        do {
            try ProjectLifecycle.rename(projectNamed: name, to: title, isArchived: isArchived)
        } catch {
            ProjectLifecycle.present(error, doing: "Couldn't rename “\(name)”")
        }
    }

    // MARK: Add link

    /// Append a link to a project's Links section — the details brief's list, reached without opening
    /// the brief.
    static func addLink(store: PMStore) {
        guard store.projectName != nil else { return }
        let labelField = NSTextField(string: "")
        labelField.placeholderString = "Label (optional)"
        let urlField = NSTextField(string: "")
        urlField.placeholderString = "https://…"

        let alert = NSAlert()
        alert.messageText = "Add Link"
        alert.informativeText = "Adds to this project's Links, alongside the ones in its details brief."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = stack([labelField, urlField])
        alert.window.initialFirstResponder = urlField

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        store.saveDetails { notes in
            var out = notes
            let entry = LinkEntry(label: label.isEmpty ? nil : label, url: url)
            // The model carries one blank entry when a project has no links; fill that rather than
            // leaving an empty row above the first real one.
            if let blank = out.links.firstIndex(where: {
                ($0.label ?? "").isEmpty && ($0.url ?? "").isEmpty && ($0.children ?? []).isEmpty
            }) {
                out.links[blank] = entry
            } else {
                out.links.append(entry)
            }
            return out
        }
    }

    // MARK: Helpers

    private static let lastDomainKey = "PMLastNewProjectDomain"

    /// An accessory view wide enough to type a project title into. `NSAlert` sizes itself to its
    /// accessory, so the width here is what stops the alert coming up as a narrow column.
    private static func stack(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for view in views { view.widthAnchor.constraint(equalToConstant: 280).isActive = true }
        stack.frame = NSRect(x: 0, y: 0, width: 280,
                             height: CGFloat(views.count) * 24 + CGFloat(views.count - 1) * 8)
        return stack
    }
}
