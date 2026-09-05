import Foundation

/// The project's canvas — the board that belongs to a project the way `docs/Notes - <Title>.md` does.
///
/// Every project is assumed to have one, or to want one: there is no "does this project do canvases?"
/// question anywhere above this file. A project that has never been given a board resolves to `nil`
/// here and gets one made on first use, which is the same shape as `resolveNotesPath` plus
/// `createNotesFromTemplate` and for the same reason — the file is a consequence of opening the thing,
/// not a decision the user has to make first.
///
/// Named `…ProjectCanvas…` rather than mirroring `getNotesPath`'s bare noun, because "canvas" stopped
/// being unambiguous in this module: `CanvasDocument`, `CanvasIO` and friends are about *a* canvas,
/// while these three are about *the project's* one.

/// Where a project's canvas goes: `docs/<Title>.canvas`, alongside its notes.
///
/// No `Canvas - ` prefix, though the notes file carries `Notes - `. That prefix exists to tell the
/// notes apart from every other markdown file in `docs/`; the extension already does that job here,
/// and the vault's own canvases are named this way — `S-003 ISD Walkable/docs/ISD Walkable.canvas`.
public func getProjectCanvasPath(projectPath: String) -> String {
    let folderName = (projectPath as NSString).lastPathComponent
    let title = projectTitle(fromFolderName: folderName)
    return (projectPath as NSString).appendingPathComponent("docs/\(title).canvas")
}

/// The project's canvas as it actually sits on disk, or nil if it hasn't got one yet.
///
/// Canonical first, then a lone canvas in `docs/`, then a lone canvas at the top of the project
/// folder. That last step is what adopts a board somebody made in Obsidian before PM had an opinion —
/// `C-002 Dnd - Strahd 2024/The Curse of Strahd.canvas` is unmistakably that project's canvas, and
/// offering to create an empty one beside it would be absurd.
///
/// Several is deliberately nil rather than a guess, which is where this parts company with
/// `resolveNotesPath`. Two `Notes - *.md` in a folder are near-duplicates of one document and picking
/// either is close enough; two canvases are two different boards. `42 Aberdeen` keeps `estimates` and
/// `insurance` side by side, and neither is "the project canvas" — silently crowning one would put a
/// button in the header that opens the wrong board every time.
public func resolveProjectCanvasPath(projectPath: String) throws -> String? {
    let canonical = getProjectCanvasPath(projectPath: projectPath)
    if FileManager.default.fileExists(atPath: canonical) { return canonical }
    let docs = (projectPath as NSString).appendingPathComponent("docs")
    for folder in [docs, projectPath] {
        let found = try canvasFileNames(in: folder)
        if found.count == 1 {
            return (folder as NSString).appendingPathComponent(found[0])
        }
    }
    return nil
}

/// Make the project's canvas, and return where it went.
///
/// It isn't empty, for the same reason the notes file isn't: a new project's notes arrive as a
/// template with the sections already in them. The board's equivalent is one card showing the notes —
/// the one document that certainly belongs to this project — so the canvas opens as a view *of* the
/// project rather than as a blank page. It's an ordinary card and deleting it is a keystroke.
///
/// - Parameter notesPath: the project's notes file, if it has one. A project whose notes haven't been
///   created yet gets a genuinely empty canvas rather than a card pointing at nothing.
public func createProjectCanvas(projectPath: String, notesPath: String? = nil) throws -> String {
    let path = getProjectCanvasPath(projectPath: projectPath)
    if FileManager.default.fileExists(atPath: path) {
        throw PmError.canvasAlreadyExists(path)
    }
    let url = URL(fileURLWithPath: path)
    var document = CanvasDocument()
    if let notesPath, let stored = vaultRelativePath(of: notesPath, from: url) {
        document.nodes = [CanvasNode(content: .file(path: stored, subpath: nil),
                                     frame: CanvasRect(x: 0, y: 0, width: 400, height: 400))]
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try document.write(to: url)
    return path
}

/// A file card's path is written the way Obsidian writes it: from the vault root, no leading slash.
/// Nil when the project isn't inside a vault at all, which is the one case where there's nothing
/// sensible to store — a card can't point outside the vault it lives in.
private func vaultRelativePath(of path: String, from canvas: URL) -> String? {
    guard let root = obsidianVaultRoot(for: canvas) else { return nil }
    let rootParts = root.standardizedFileURL.pathComponents
    let fileParts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    guard fileParts.count > rootParts.count, Array(fileParts.prefix(rootParts.count)) == rootParts else {
        return nil
    }
    return fileParts.dropFirst(rootParts.count).joined(separator: "/")
}

/// The `.canvas` files directly in a folder, sorted, with a missing folder reading as none.
private func canvasFileNames(in folder: String) throws -> [String] {
    let entries: [String]
    do {
        entries = try FileManager.default.contentsOfDirectory(atPath: folder)
    } catch {
        if isFileNotFoundError(error) { return [] }
        throw PmError.cannotListDirectory(path: folder, message: (error as NSError).localizedDescription)
    }
    return entries.filter { $0.hasSuffix(".canvas") }.sorted()
}
