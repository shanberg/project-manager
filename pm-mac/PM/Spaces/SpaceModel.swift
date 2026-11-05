import Foundation

/// A space: a board and its workspaces that belong to no project. docs/spaces.md § Spaces.
///
/// - What it holds is a canvas file of its own, `~/.config/pm/spaces/<id>.canvas`, opened in the
///   ordinary window: tiles, tabs, workspaces, pop-outs and every card kind — web, folder, file, note.
/// - What this records is only what a file can't say: a name (none to start), an icon, a colour.
/// - Never the focused project; no notes, tasks, sessions or time — a window on a file changes nothing.
struct Space: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var icon: String
    var color: String

    init(id: String = UUID().uuidString, name: String = "", icon: String = "globe", color: String) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
    }

    /// What a space is called where it has to be called something: its name, or Untitled Space.
    var title: String { name.isEmpty ? "Untitled Space" : name }

    /// Where its canvas lives under `folder`.
    func canvas(in folder: URL) -> URL { folder.appendingPathComponent("\(id).canvas") }
}

/// Every space, in dock order, read and written as one file.
struct SpaceFile: Codable, Equatable {
    var spaces: [Space] = []

    static func read(_ url: URL) -> SpaceFile {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(SpaceFile.self, from: data) else { return SpaceFile() }
        return file
    }

    func write(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The space a canvas file is, when it is one.
    func space(forCanvas url: URL, in folder: URL) -> Space? {
        let path = url.standardizedFileURL.path
        return spaces.first { $0.canvas(in: folder).standardizedFileURL.path == path }
    }
}

/// An empty canvas, as JSON Canvas writes one.
enum SpaceCanvas {
    static let empty = Data(#"{"nodes":[],"edges":[]}"#.utf8)
}
