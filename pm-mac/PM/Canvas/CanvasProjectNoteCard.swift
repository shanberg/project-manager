import Foundation
import PmLib

/// The project's own note, as a card the board can offer to put back.
///
/// `createProjectCanvas` starts every project's board with one card on it: a file card pointing at
/// `docs/Notes - <Title>.md`, so the canvas opens as a view *of* the project rather than as a blank
/// page. It is an ordinary card, deleting it is a keystroke — and until now there was no way to get it
/// back. You would have had to know the file's name, find New File…, and go looking through the vault
/// for the one document the board was made out of.
///
/// So the add menu offers it, **and only when the board hasn't got it**. A permanent "New Project
/// Note" would be an invitation to put a second copy of the same document on the same board, which is
/// not a thing anybody wants and is the sort of thing a menu should decline to make easy. Offered
/// conditionally it is not really a fifth command at all: it is the board noticing something is
/// missing and saying so, in the place you would go to fix it.
///
/// The card built here is the card `createProjectCanvas` builds — same content, same 400×400 — so a
/// board you have restored is the board you were given rather than an approximation of it.
@MainActor
enum CanvasProjectNoteCard {
    /// The size the project's own card is made at, in `createProjectCanvas`. Square, and larger than
    /// the file card's default: this one is a document you read rather than a file you refer to.
    static let size = (width: 400.0, height: 400.0)

    /// The notes file this board's project keeps, or nil if this board isn't a project's.
    ///
    /// **The test is the file, not the index.** `resolveNotesPath` finding a real `Notes - *.md` beside
    /// the board is what makes this a project's board — the same name-shaped convention
    /// `projectFolder(ofNotesPath:)` reads in the other direction, and deliberately not a lookup in
    /// `ProjectIndex`. The index is built after launch and a board can be asked this before it is
    /// ready, so an index test would answer "no project" for a board that plainly has one, and the
    /// answer is remembered.
    ///
    /// It costs nothing to be generous here. If the index later fails to recognise the folder, the
    /// card renders the file as the markdown it is, which `CanvasProjectSource` already treats as the
    /// right failure — a note PM cannot place is still a note somebody wrote.
    ///
    /// A canvas opened from anywhere else — the vault's own boards, another app's Open With — has no
    /// notes file a step above it and gets no offer, which is right: it is a canvas, not a project's
    /// board.
    static func notes(forCanvasAt canvas: URL) -> URL? {
        // `docs/<Title>.canvas` is where `getProjectCanvasPath` puts it; a board adopted from Obsidian
        // can sit at the top of the project folder instead. Both are one step from the project.
        let folder = canvas.deletingLastPathComponent()
        let project = folder.lastPathComponent == "docs" ? folder.deletingLastPathComponent() : folder
        // `try?` flattens the throw and the "no notes file" nil into the one answer this wants.
        guard let found = try? resolveNotesPath(projectPath: project.path) else { return nil }
        return URL(fileURLWithPath: found)
    }

    /// Whether that note is already on the board.
    ///
    /// **Compared as written, not as resolved.** `CanvasFileResolver.resolve` is the honest test and it
    /// touches the disk, and this is asked again on every change the document sees — which during a
    /// drag is every frame of it. What it compares instead is the vault-relative path the card would
    /// be *stored* as, which is pure path arithmetic, against the one each card carries; a card whose
    /// path is written from somewhere else in the tree still matches on the tail. Being wrong costs a
    /// menu item that shouldn't be there, or isn't — never a broken board.
    static func isOn(_ document: CanvasDocument, notes: URL, resolver: CanvasFileResolver) -> Bool {
        id(on: document, notes: notes, resolver: resolver) != nil
    }

    /// *Which* card it is, when it is on the board — what the note-only view tiles to (§7d), and what
    /// `isOn` is asking without needing the answer.
    static func id(on document: CanvasDocument, notes: URL,
                   resolver: CanvasFileResolver) -> String? {
        let wanted = (resolver.storablePath(for: notes) ?? notes.path).lowercased()
        return document.nodes.first { node in
            guard case .file(let path, _) = node.content else { return false }
            let stored = path.lowercased()
            return stored == wanted || stored.hasSuffix("/" + wanted) || wanted.hasSuffix("/" + stored)
        }?.id
    }

    /// What a new project's first workspace is called.
    static let notesWorkspaceName = "Notes"

    /// Keep a workspace of this board's project card alone, as `notesWorkspaceName`, and say what it
    /// was called — or nil when there was nothing to seed: a board with no project card on it (a
    /// project outside a vault gets an empty canvas), or one that already has a workspace by that
    /// name, which is somebody's and is not replaced. See `ProjectWindowController.seedNotesWorkspace`.
    ///
    /// Handed the document rather than opening it, so this file stays free of the store registry and
    /// compiles into the hostless test bundle.
    static func seedNotesWorkspace(on document: CanvasDocument, at url: URL,
                                   resolver: CanvasFileResolver) -> String? {
        let name = notesWorkspaceName
        guard !CanvasWorkspaces.exists(name, of: url),
              let notes = notes(forCanvasAt: url),
              let card = id(on: document, notes: notes, resolver: resolver)
        else { return nil }
        // The arrangement you last chose, so the first card you tile in beside the notes lands the way
        // your other workspaces do. One tile looks the same in any of them.
        let tiling = CanvasViewState.Tiling(ids: [card],
                                            arrangement: CanvasTiling.savedArrangement ?? .masterStack,
                                            masterFraction: CanvasTiling.savedMasterFraction,
                                            sizes: nil)
        CanvasWorkspaces.save(tiling, as: name, for: url)
        return name
    }

    /// The card itself, centred on `at`.
    static func node(for notes: URL, at where_: CanvasPoint,
                     resolver: CanvasFileResolver) -> CanvasNode {
        // Stored the way Obsidian stores it — from the vault root — so the card means the same thing in
        // both apps. Exactly what `addFileCard` does, and what `createProjectCanvas` wrote originally.
        let path = resolver.storablePath(for: notes) ?? notes.path
        return CanvasNode(content: .file(path: path, subpath: nil),
                          frame: CanvasRect(x: where_.x - size.width / 2,
                                            y: where_.y - size.height / 2,
                                            width: size.width, height: size.height))
    }
}
