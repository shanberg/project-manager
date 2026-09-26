import Foundation

/// Files sent into a project from outside it — the Services menu, for now.
///
/// **Moved, not copied**, because sending a file to a project is filing it: a copy would leave the
/// original where it was, and the one you meant to put away would still be in Downloads.
public enum ProjectIntake {
    /// Where sent files go: the project's resources folder, one of the folders every project is made
    /// with (`defaultSubfolders`), made if it has gone.
    public static let folder = "resources"

    /// Move `files` into the project, answering where each one landed.
    ///
    /// A name already taken there gets a number, as the Finder gives one — `brief 2.pdf` — rather than
    /// replacing what is there. A file already inside the folder stays where it is.
    public static func move(_ files: [URL], intoProject projectPath: String) throws -> [URL] {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: projectPath).appendingPathComponent(folder, isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        return try files.map { file in
            let source = file.standardizedFileURL
            if source.deletingLastPathComponent().path == home.standardizedFileURL.path { return source }
            let target = free(source.lastPathComponent, in: home)
            try fm.moveItem(at: source, to: target)
            return target
        }
    }

    /// `name` in `folder`, or the first `name N` that isn't taken.
    static func free(_ name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(name)
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}

/// A file card's path for `file` on the board at `canvas` — the way Obsidian writes it, from the vault
/// root — or nil when the file isn't in the board's vault.
public func canvasFileCardPath(of file: URL, onCanvasAt canvas: URL) -> String? {
    vaultRelativePath(of: file.path, from: canvas)
}
