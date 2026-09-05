import Foundation

/// Where a canvas's file card actually points, now.
public enum CanvasFileLocation: Equatable, Sendable {
    /// The file is where the canvas says it is.
    case found(URL)
    /// The file exists, somewhere other than where the canvas says. `stored` is the path in the file,
    /// kept so the window can offer to correct it.
    case moved(URL, stored: String)
    /// Nothing by that name, anywhere PM knows to look.
    case missing

    public var url: URL? {
        switch self {
        case .found(let url), .moved(let url, _): return url
        case .missing: return nil
        }
    }

    public var hasMoved: Bool { if case .moved = self { return true }; return false }
}

/// Finding the file a canvas card names — including when the canvas is wrong about where it is.
///
/// Obsidian stores a file card's path from the vault root and does not update it when the file moves.
/// That is a fair design for a vault where notes are filed once and stay filed. It is not a fair one
/// for a vault PM manages, because PM's whole job is moving folders: archiving a finished project
/// moves it from `Projects/` to `Archive/`, and renumbering it changes the name every stored path
/// begins with. In a real vault this had broken **31 of 68** file cards — nearly half the boards were
/// showing empty rectangles, and Obsidian had no way to know better.
///
/// PM does know better, and that is the reason this feature earns its place here rather than being a
/// worse copy of Obsidian's canvas. A project's *code* is the part of its name that never moves — see
/// `projectCode(fromName:)` — so a stored path with a project folder in it can be re-pointed at
/// wherever that project lives now, whether it was archived, renumbered into another domain, or
/// retitled. `matchWrittenName` is the same rule PM already uses to resolve a `[[wikilink]]` and a
/// waiting-on target; a canvas path is one more written name that has drifted.
///
/// The order is nearest-truth-first: what the file says, then the folder the canvas is in, then the
/// project the path names wherever it now lives, then a unique file of that name anywhere in the
/// vault. A card is only reported `.moved` — the state the window can offer to repair — when an
/// earlier, more literal reading failed.
@MainActor
public final class CanvasFileResolver {
    private let vaultRoot: URL?
    private let canvasFolder: URL
    /// The PARA roots and the folders directly inside each, for the project-name step. Read once:
    /// three directory listings, against a resolver that is asked once per card per redraw.
    private var roots: [(root: URL, folders: [String])] = []
    private var answers: [String: CanvasFileLocation] = [:]
    /// Every file in the vault by name — as a path *relative to the vault*, not as a URL. Built only
    /// if a path gets as far as the last step; most vaults never build it, and one that does builds it
    /// once.
    ///
    /// Relative because a `URL` from `FileManager`'s enumerator is spelled in resolved form
    /// (`/private/var/…`) while one built by appending to the vault root keeps the vault's own
    /// spelling (`/var/…`). The two are the same file and compare unequal, so a card found through the
    /// index would not match the same card found directly — and `storablePath`, which compares path
    /// components against the vault root, would decline to make a path for it. One spelling
    /// throughout, and the vault root's is the one that matters.
    private var byName: [String: [String]]?

    public init(canvas: URL, vaultRoot: URL? = nil, paths: ResolvedPaths? = nil) {
        self.canvasFolder = canvas.deletingLastPathComponent()
        self.vaultRoot = vaultRoot ?? obsidianVaultRoot(for: canvas)
        loadRoots(paths)
    }

    /// Re-read the folder listings and forget every answer. For a window that was open while a project
    /// was archived from somewhere else in the app.
    public func refresh(paths: ResolvedPaths? = nil) {
        answers.removeAll()
        byName = nil
        loadRoots(paths)
    }

    private func loadRoots(_ paths: ResolvedPaths?) {
        guard let paths = paths ?? (try? loadConfig()).flatMap({ try? resolvePaths(config: $0) })
        else { roots = []; return }
        roots = ProjectScope.allCases.compactMap { scope in
            let url = URL(fileURLWithPath: scope.path(in: paths))
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            let folders = names.filter { name in
                var isDirectory: ObjCBool = false
                let there = FileManager.default.fileExists(
                    atPath: url.appendingPathComponent(name).path, isDirectory: &isDirectory)
                return there && isDirectory.boolValue && !name.hasPrefix(".")
            }
            return folders.isEmpty ? nil : (url, folders)
        }
    }

    // MARK: Resolving

    public func resolve(_ stored: String) -> CanvasFileLocation {
        if let cached = answers[stored] { return cached }
        let found = locate(stored)
        answers[stored] = found
        return found
    }

    /// The vault-root-relative path `url` should be stored as, for repairing a card that has moved.
    /// Nil when the file is outside the vault, where no such path exists.
    public func storablePath(for url: URL) -> String? {
        guard let vaultRoot else { return nil }
        let parts = url.standardizedFileURL.pathComponents
        let rootParts = vaultRoot.standardizedFileURL.pathComponents
        guard parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts
        else { return nil }
        return parts.dropFirst(rootParts.count).joined(separator: "/")
    }

    private func locate(_ stored: String) -> CanvasFileLocation {
        let path = stored.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return .missing }

        // 1. What the file says, read the way the format defines it.
        if let vaultRoot {
            let there = vaultRoot.appendingPathComponent(path)
            if exists(there) { return .found(there) }
        }
        // 2. Beside the canvas. Not what the format says, but a canvas outside any vault has no other
        //    meaning to give a relative path, and a hand-written one usually means this.
        let beside = canvasFolder.appendingPathComponent(path)
        if exists(beside) { return vaultRoot == nil ? .found(beside) : .moved(beside, stored: stored) }

        // 3. The project the path names, wherever that project is now.
        if let moved = followTheProject(in: path) { return .moved(moved, stored: stored) }

        // 4. A file of that name, if there is exactly one in the vault.
        if let only = onlyFileNamed((path as NSString).lastPathComponent) {
            return .moved(only, stored: stored)
        }
        return .missing
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Re-point a stored path at the project folder it names.
    ///
    /// The path is walked from the outside in for a component that names a project or area under one
    /// of the PARA roots, and the rest of the path is hung off wherever that folder turned out to be.
    /// Outside-in rather than first-code-wins: a path can hold more than one project-shaped name (a
    /// card in one project's canvas pointing into another's), and the outermost one is the folder the
    /// rest of the path hangs from.
    ///
    /// **Every reading is tried, and the file on disk decides.** A component can name a folder in more
    /// than one way at once, and the strongest-looking reading is not always the right one — in a real
    /// vault, `V-002 Flexcompute` matched a folder by its *code*, because that project had been
    /// renumbered to `W-002` and a different project had since been given the freed `V-002`. Answering
    /// from the code alone found a real folder, the wrong one, and stopped looking. So each reading
    /// becomes a candidate path and the first that is actually there wins, which makes a wrong reading
    /// cost nothing but a `stat`.
    private func followTheProject(in path: String) -> URL? {
        let parts = path.split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() where index < parts.count - 1 {
            let rest = Array(parts.dropFirst(index + 1))
            for reading in projectFolderReadings(for: part) {
                for (root, folders) in roots {
                    guard let folder = reading(folders) else { continue }
                    let rebuilt = rest.reduce(root.appendingPathComponent(folder)) {
                        $0.appendingPathComponent($1)
                    }
                    if exists(rebuilt) { return rebuilt }
                }
            }
        }
        return nil
    }

    /// The ways a written folder name can still name a folder, strongest evidence first.
    ///
    /// These are the same readings `matchWrittenName` applies, and this deliberately doesn't call it:
    /// it answers with one folder, and this needs the alternatives. Its job is to decide; here the
    /// deciding belongs to whether the file is there.
    ///
    /// The order is what drift actually does to a name. Archiving a project changes nothing about it,
    /// so an **exact** match is the strongest thing a stored path can still say. Renumbering — moving
    /// a project between domains — changes the code and keeps the **title**. Retitling keeps the
    /// **code**. Title before code because a whole title matching is far more specific than five
    /// characters of code, and because a freed code gets reused while a title effectively doesn't —
    /// which is the exact pair that went wrong before this was ordered.
    private func projectFolderReadings(for written: String) -> [([String]) -> String?] {
        let query = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let queryTitle = projectTitle(fromFolderName: query)
        let queryCode = projectCode(fromName: query)

        func only(_ matches: [String]) -> String? { matches.count == 1 ? matches[0] : nil }

        return [
            // The name it was written as, still standing — an archived project, most of the time.
            { folders in folders.first { $0.caseInsensitiveCompare(query) == .orderedSame } },
            // Renumbered: `V-002 Flexcompute` is now `W-002 Flexcompute`.
            { folders in
                guard queryCode != nil, !queryTitle.isEmpty else { return nil }
                return only(folders.filter {
                    projectTitle(fromFolderName: $0).caseInsensitiveCompare(queryTitle) == .orderedSame
                })
            },
            // Retitled: `W-002 Flexcompute` is now `W-002 Flexco Evaluation`.
            { folders in
                guard let queryCode else { return nil }
                return only(folders.filter {
                    projectCode(fromName: $0)?.caseInsensitiveCompare(queryCode) == .orderedSame
                })
            },
            // A name that carries no code at all — an area, which is named rather than numbered and
            // whose only stable spelling is the one above. Kept as a distinct, last reading so that a
            // prefix is never preferred over a project's code.
            { folders in
                guard queryCode == nil else { return nil }
                return only(folders.filter { $0.lowercased().hasPrefix(query.lowercased()) })
            },
        ]
    }

    /// The single file in the vault with this name, or nil when there are none or several.
    ///
    /// Several is deliberately nil rather than a guess. `Notes.md` exists in every project in a PARA
    /// vault, and quietly showing one project's notes on another project's board would be worse than
    /// showing the card as missing — the card would look right and be wrong. The project step above is
    /// what resolves those, because it has a reason to prefer one; this step has none.
    private func onlyFileNamed(_ name: String) -> URL? {
        guard let vaultRoot, !name.isEmpty else { return nil }
        if byName == nil { byName = indexVault(vaultRoot) }
        guard let matches = byName?[name], matches.count == 1 else { return nil }
        return vaultRoot.appendingPathComponent(matches[0])
    }

    /// Every file under `root`, by name, as a path relative to it.
    ///
    /// `enumerator(atPath:)` rather than the `URL` overload precisely because it yields relative paths
    /// and never has to be asked where the root is. Subtracting one URL from another looked simpler and
    /// was wrong: `/var/…` and `/private/var/…` name the same folder with a different number of path
    /// components, so the arithmetic silently produced a doubled path.
    private func indexVault(_ root: URL) -> [String: [String]] {
        var index: [String: [String]] = [:]
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return index }
        while let relative = walker.nextObject() as? String {
            let name = (relative as NSString).lastPathComponent
            // `.obsidian`, `.trash`, and anything else dot-prefixed is vault plumbing, not a card's
            // subject — and `.trash` in particular holds deleted copies under their original names,
            // which is the one thing that could make a unique name look ambiguous.
            if name.hasPrefix(".") {
                walker.skipDescendants()
                continue
            }
            guard (walker.fileAttributes?[.type] as? FileAttributeType) == .typeRegular else { continue }
            index[name, default: []].append(relative)
        }
        return index
    }
}
