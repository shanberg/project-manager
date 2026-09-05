import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PmLib

/// A window on one canvas.
///
/// A board wants the whole frame, so it gets one — full-size content under a hidden titlebar, with the
/// window's controls floating over the board instead of occupying a bar across the top of it. That is
/// the project window's chrome, and using it here rather than something like it is the point: a canvas
/// is a document window in the same app and shouldn't be a second idea of what a window looks like.
/// See `CanvasHeaderModel`.
///
/// Tabbable, so several boards stack the way several projects do, and one window per file — asking for
/// a canvas that is already open brings its window forward rather than opening a second view of the
/// same document.
@MainActor
final class CanvasWindowController: NSWindowController, NSWindowDelegate {
    let store: CanvasDocumentStore
    /// The board and all its chrome. Everything this window does to a canvas, it does through here —
    /// which is what lets a project window put the same pane in its content column.
    private let pane: CanvasPaneController

    /// Every open canvas, by the file it shows.
    private static var open: [URL: CanvasWindowController] = [:]

    // MARK: Opening

    /// Show `url`, or bring its window forward if it's already up.
    ///
    /// A canvas that won't parse is reported here rather than opening an empty window: an empty board
    /// and a broken file look identical, and only one of them is something you can fix.
    @discardableResult
    static func open(url: URL) -> CanvasWindowController? {
        let key = url.standardizedFileURL
        if let existing = open[key] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        do {
            let controller = try CanvasWindowController(url: key)
            Log.write("canvas opened: \(key.lastPathComponent) "
                + "nodes=\(controller.store.document.nodes.count) "
                + "edges=\(controller.store.document.edges.count)")
            open[key] = controller
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return controller
        } catch {
            Log.write("canvas open failed: \(key.lastPathComponent): \(error)")
            let alert = NSAlert()
            alert.messageText = "Couldn't open \(url.lastPathComponent)."
            alert.informativeText = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            return nil
        }
    }

    /// Open a project's own canvas, making it if the project hasn't got one yet.
    ///
    /// Here rather than in either caller because the header button and File ▸ Project Canvas are the
    /// same errand reached two ways, and the half worth not duplicating is the failure: creating the
    /// board writes a file, so a refusal has to be *said*, not logged. Silence and a window that
    /// didn't appear is the one outcome that leaves you with nothing to act on.
    static func openProjectCanvas(for store: PMStore) {
        store.openableCanvasPath { result in
            switch result {
            case .success(let path):
                open(url: URL(fileURLWithPath: path))
            case .failure(let error):
                let alert = NSAlert()
                alert.messageText = "Couldn't open the project canvas."
                alert.informativeText = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    /// The open panel behind File ▸ Open Canvas.
    static func runOpenPanel() {
        let panel = NSOpenPanel()
        // By extension rather than by the declared type: `md.obsidian.canvas` is only *imported* by
        // PM, so on a Mac without Obsidian installed it may not be registered at all, and a panel
        // filtered on an unregistered type shows nothing openable.
        if let canvas = UTType(filenameExtension: "canvas") {
            panel.allowedContentTypes = [canvas]
        }
        panel.allowsMultipleSelection = true
        panel.message = "Choose an Obsidian canvas."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url: url) }
    }

    // MARK: Building

    private init(url: URL) throws {
        let store = try CanvasStoreRegistry.store(for: url)
        self.store = store
        pane = CanvasPaneController(store: store)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                          .fullSizeContentView],
                              backing: .buffered, defer: false)
        // The project window's chrome, for the same reasons and by the same route: no visible title, no
        // toolbar in the UI sense, content running to the top of the frame. The title is still *set* —
        // `titleVisibility` only hides it from the titlebar, while window tabs, the Window menu and ⌘`
        // all keep reading it, and `representedURL` still gives the proxy icon its file.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = url.deletingPathExtension().lastPathComponent
        window.representedURL = url
        window.contentMinSize = NSSize(width: 480, height: 360)
        window.tabbingIdentifier = "PMCanvas"
        window.tabbingMode = .automatic
        window.setFrameAutosaveName("PMCanvasWindow")
        // An empty toolbar, purely for its geometry — the taller unified titlebar and the lower,
        // further-inset traffic lights that go with it. Exactly the arrangement `ProjectWindowController`
        // explains at length; it has no delegate and so no items, and customization is off, so there is
        // nothing here for anyone to find or toggle.
        let toolbar = NSToolbar(identifier: "PMCanvasTitlebar")
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        super.init(window: window)

        pane.title_ = window.title
        window.contentViewController = pane
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The document's undo stack, which every window showing this canvas shares — see
    /// `CanvasDocumentStore.undoManager`. Handed back here so ⌘Z reaches the board's changes rather than
    /// whatever text field last had focus.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { store.undoManager }

    // MARK: Closing

    func windowWillClose(_ notification: Notification) {
        pane.teardown()
        Self.open.removeValue(forKey: store.url)
    }
}
