import AppKit
import PmLib

/// Every space and the window it opens in. docs/spaces.md § Spaces.
///
/// - The list is `~/.config/pm/spaces.json`; each space's board is `~/.config/pm/spaces/<id>.canvas`.
/// - A space opens in the ordinary window on its canvas (`WindowManager.open(canvas:)`), which already
///   leaves the focused project alone and comes back at launch with the other windows.
@MainActor
final class Spaces {
    static let shared = Spaces()

    private(set) var file: SpaceFile
    private var saveQueued = false

    static var fileURL: URL { PMFiles.configDir.appendingPathComponent("spaces.json") }
    static var folder: URL { PMFiles.configDir.appendingPathComponent("spaces", isDirectory: true) }

    private init() {
        file = SpaceFile.read(Self.fileURL)
        Self.carryOverTabs(from: Self.fileURL, into: Self.folder)
    }

    /// Spaces made before they were boards (2026-11-04) kept their pages as tabs in `spaces.json`. A space
    /// with no canvas yet gets those pages as web cards, in a row, once; the old keys go on the next write.
    static func carryOverTabs(from list: URL, into folder: URL) {
        guard let data = try? Data(contentsOf: list),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spaces = object["spaces"] as? [[String: Any]] else { return }
        for space in spaces {
            guard let id = space["id"] as? String else { continue }
            let canvas = folder.appendingPathComponent("\(id).canvas")
            guard !FileManager.default.fileExists(atPath: canvas.path) else { continue }
            let tabs = ["favorites", "pinned", "today"].flatMap { space[$0] as? [[String: Any]] ?? [] }
            let urls = tabs.compactMap { $0["url"] as? String }
            guard !urls.isEmpty else { continue }
            let nodes: [[String: Any]] = urls.enumerated().map { index, url in
                ["id": UUID().uuidString.lowercased(), "type": "link", "url": url,
                 "x": index * 440, "y": 0, "width": 400, "height": 400]
            }
            guard let json = try? JSONSerialization.data(withJSONObject: ["nodes": nodes, "edges": []],
                                                         options: [.prettyPrinted]) else { continue }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? json.write(to: canvas, options: .withoutOverwriting)
            Log.write("spaces: carried \(urls.count) tab(s) into \(id).canvas")
        }
    }

    var all: [Space] { file.spaces }
    func space(_ id: String) -> Space? { file.spaces.first { $0.id == id } }
    func canvas(of id: String) -> URL? { space(id)?.canvas(in: Self.folder) }

    /// The space a window's canvas is, when it is one.
    func space(forCanvas url: URL?) -> Space? {
        url.flatMap { file.space(forCanvas: $0, in: Self.folder) }
    }

    /// The window showing the space, if one is open.
    func window(of id: String) -> ProjectWindowController? {
        guard let canvas = canvas(of: id)?.standardizedFileURL else { return nil }
        return WindowManager.shared.controllers.first { $0.openedCanvas?.standardizedFileURL == canvas && !$0.isCarrier }
    }

    func isOpen(_ id: String) -> Bool { window(of: id)?.isVisible ?? false }

    // MARK: Changing

    func change(_ id: String, _ edit: (inout Space) -> Void) {
        guard let index = file.spaces.firstIndex(where: { $0.id == id }) else { return }
        let before = file.spaces[index]
        edit(&file.spaces[index])
        guard file.spaces[index] != before else { return }
        window(of: id)?.applyTitle()
        CanvasSatelliteDock.shared.refresh()
        save()
    }

    private func save() {
        guard !saveQueued else { return }
        saveQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            saveQueued = false
            flush()
        }
    }

    func flush() {
        do { try file.write(Self.fileURL) } catch { Log.write("spaces: couldn't write: \(error)") }
    }

    // MARK: Windows

    func show(_ id: String) {
        guard let canvas = canvas(of: id) else { return }
        if !FileManager.default.fileExists(atPath: canvas.path) { try? makeCanvas(at: canvas) }
        WindowManager.shared.open(canvas: canvas)
        CanvasSatelliteDock.shared.refresh()
    }

    private func makeCanvas(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SpaceCanvas.empty.write(to: url, options: .withoutOverwriting)
    }

    // MARK: Making and removing

    /// File ▸ New Space: untitled, an empty board in its window. Named later, if ever.
    func newSpace() {
        let made = Space(color: Self.nextColor(after: file.spaces.count))
        file.spaces.append(made)
        flush()
        show(made.id)
    }

    /// Colours in turn, so two new spaces in a row don't look alike.
    static func nextColor(after count: Int) -> String {
        let names: [ProjectColor.Name] = [.blue, .pink, .teal, .orange, .purple, .green, .indigo, .red, .brown, .mint]
        return ProjectColor.named(names[count % names.count]).value
    }

    func rename(_ id: String) {
        guard let space = space(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Space"
        let field = NSTextField(string: space.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        field.placeholderString = "Untitled Space"
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Empty is allowed: it makes the space untitled again.
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        change(id) { $0.name = name }
    }

    func setColor(_ id: String, _ color: ProjectColor) { change(id) { $0.color = color.value } }

    /// Delete a space and its board, behind a confirmation. The board goes to the Trash.
    func delete(_ id: String) {
        guard let space = space(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(space.title)”?"
        alert.informativeText = "Its board and everything on it go to the Trash."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        window(of: id)?.close()
        if let canvas = canvas(of: id) { try? FileManager.default.trashItem(at: canvas, resultingItemURL: nil) }
        file.spaces.removeAll { $0.id == id }
        flush()
        CanvasSatelliteDock.shared.refresh()
    }
}
