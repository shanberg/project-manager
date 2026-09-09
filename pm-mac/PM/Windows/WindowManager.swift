import AppKit
import PmLib

/// Owns the app's project windows: opening, focusing, retargeting, closing, and remembering which
/// projects were open across launches.
///
/// **A project can have as many windows as you want, and reaching for one still finds it.** Those are
/// two different errands and the app used to answer both the same way. "Take me to this project" — the
/// menubar, the hotkey, the Dock, a `[[…]]` token — means *a* window on it, and bringing the one that
/// exists forward is exactly right. "Open this in a new window" means a second one, and answering that
/// with the window you are already looking at is the same as doing nothing, which is how it read.
///
/// So the reuse is a parameter rather than a rule, and it is off wherever the ask was explicit. See
/// `open(projectKey:reusingExistingWindow:)` and `retarget`. `ProjectTab` tells the rest of this
/// story: a window used to be a project because a project had one shape, and this was two of the five
/// places that assumed it.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private(set) var controllers: [ProjectWindowController] = []

    // MARK: Opening

    /// Bring up a window for `projectKey`.
    ///
    /// `reusingExistingWindow` is the difference between the two errands in the type comment above.
    /// Left at its default, an open that finds a window already showing the project brings that one
    /// forward — which is what every "take me to this project" surface means. Passed `false`, it makes
    /// a second window regardless, which is what the two Open in New Window items and ⌥-click mean, and
    /// what restoring a saved session means when the same project was open in two windows last time.
    @discardableResult
    func open(projectKey: String?, reusingExistingWindow: Bool = true,
              canvas: URL? = nil) -> ProjectWindowController {
        if reusingExistingWindow,
           let existing = controllers.first(where: { $0.projectKey == projectKey }) {
            existing.show()
            return existing
        }
        let controller = makeController(projectKey: projectKey, canvas: canvas)
        controllers.append(controller)
        Log.write("window opened: \(projectKey ?? "no project") (\(controllers.count) open)")
        rememberOpenProjects()
        // Every project window is the same window type at the same remembered frame, so a second one
        // would open exactly on top of the first. Step it off the frontmost window the way AppKit
        // cascades any other new window.
        if let front = frontmost?.window, let new = controller.window,
           front !== new, front.isVisible {
            new.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY))
        }
        controller.show()
        // **A window with no project has one thing to offer, so it offers it.** This used to open onto
        // a sentence saying "No focused project" and telling you which key would take you somewhere;
        // the list of projects is right there in the same window, and revealing it with the keyboard in
        // it is that key, already pressed. A window opened on a canvas file is not projectless in this
        // sense — it has a document — so it is left alone.
        if projectKey == nil, canvas == nil { controller.revealProjectList() }
        return controller
    }

    /// Open a window on one canvas file — Finder's "Open With ▸ PM", and File ▸ Open Canvas.
    ///
    /// **A window on a canvas is a project window with no project.** A `.canvas` can live anywhere in
    /// the vault and several in a real one belong to no project at all, so this used to be answered by
    /// a second window type — its own registry, its own chrome, no tabs, and a standing "except in a
    /// canvas window" clause on every feature a project window grew. Since a project window renders a
    /// board in a tab, the second type earned nothing; the projectless window it leaves behind is a
    /// state the app already has, and the sidebar in it is the way to a project rather than the absence
    /// of one. See `ProjectWindowController.openedCanvas`.
    ///
    /// One window per file, like before: asking for a canvas that is already up brings it forward
    /// rather than opening a second view of the same document.
    ///
    /// A canvas that won't parse is reported here rather than opened, because an empty board and a
    /// broken file look identical and only one of them is something you can fix. Read for the answer
    /// rather than by taking a store: taking one and giving it back would write the file on the way
    /// out, which is a great deal to do to a file you have only been asked to look at.
    @discardableResult
    func open(canvas url: URL) -> ProjectWindowController? {
        let key = url.standardizedFileURL
        if let existing = controllers.first(where: { $0.openedCanvas == key }) {
            existing.show()
            return existing
        }
        do {
            let document = try CanvasDocument.read(contentsOf: key)
            Log.write("canvas opened: \(key.lastPathComponent) "
                + "nodes=\(document.nodes.count) edges=\(document.edges.count)")
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
        return open(projectKey: nil, reusingExistingWindow: false, canvas: key)
    }

    /// Open a window on the project a `[[…]]` names, given the folder name written inside it.
    ///
    /// The app-wide half of `ProjectWindowState.openProject(named:)`. A project window retargets itself
    /// — the token is in a note you're reading, and the window it's in is where you want to end up —
    /// but the surfaces with no window of their own (the immersive session note, the quick bar's note
    /// mode) have nothing to retarget, so for them following a token means putting a window in front.
    ///
    /// A name that resolves to nothing does nothing, and returns false so a caller can decline to
    /// dismiss itself over it. `[[Dana]]` is a person; clicking it is not an error and should not
    /// close the thing you were writing in.
    @discardableResult
    func open(named folder: String) -> Bool {
        guard let key = ProjectIndex.shared.projectKey(forFolder: folder) else { return false }
        open(projectKey: key)
        return true
    }

    /// Show `projectKey` in `controller` — what clicking a row in that window's sidebar means.
    ///
    /// **This window, always.** It used to hand the errand to whichever other window already had the
    /// project and leave the asking one where it was, on the grounds that two windows on one project
    /// would show the same store twice with nothing to tell them apart. With two windows open that made
    /// clicking a row in the sidebar do nothing to the window you clicked in, which is not a behaviour
    /// any list on the Mac has — and the premise is gone anyway: the two windows are told apart by
    /// their tabs, and they share one store and one undo stack (`StoreRegistry` is refcounted), so
    /// editing in both is coherent rather than a race.
    func retarget(_ controller: ProjectWindowController, to projectKey: String) {
        let previous = controller.projectKey
        let store = StoreRegistry.shared.acquire(projectKey)
        controller.retarget(to: store, projectKey: projectKey)
        StoreRegistry.shared.release(previous)
        rememberOpenProjects()
    }

    /// The window a command should act on: the main one, else the key one, else the first open.
    var frontmost: ProjectWindowController? {
        if let main = NSApp.mainWindow?.windowController as? ProjectWindowController { return main }
        if let key = NSApp.keyWindow?.windowController as? ProjectWindowController { return key }
        return controllers.first
    }

    /// Open (or focus) a window for whatever project is currently focused — the menubar's "Open
    /// Window", the ⌃⌥P hotkey, the Dock icon, and the Spotlight/Siri hand-offs all land here.
    @discardableResult
    func openFocusedProject() -> ProjectWindowController {
        open(projectKey: PMFiles.focusedProjectKey())
    }

    // MARK: Lifecycle

    private func makeController(projectKey: String?, canvas: URL? = nil) -> ProjectWindowController {
        let store = StoreRegistry.shared.acquire(projectKey)
        // Only a session's first window opens with the sidebar; the rest are opened to see another
        // project beside it, not to carry a second copy of the project list.
        let controller = ProjectWindowController(projectKey: projectKey,
                                                 store: store,
                                                 startsWithSidebar: controllers.isEmpty
                                                    && ProjectWindow.isSidebarVisible,
                                                 // The frame is the window type's, not the project's,
                                                 // so exactly one window owns it: the one opening into
                                                 // an empty screen. See `ProjectWindowController.init`.
                                                 remembersFrame: controllers.isEmpty,
                                                 canvas: canvas)
        controller.onClose = { [weak self] closed in self?.windowClosed(closed) }
        controller.onOpenProject = { [weak self, weak controller] key, inNewWindow in
            guard let self else { return }
            if inNewWindow || controller == nil {
                // Explicit: a second window on this project if that is what it takes.
                self.open(projectKey: key, reusingExistingWindow: !inNewWindow)
            } else if let controller {
                self.retarget(controller, to: key)
            }
        }
        return controller
    }

    private func windowClosed(_ controller: ProjectWindowController) {
        controllers.removeAll { $0 === controller }
        Log.write("window closed: \(controller.projectKey ?? "no project") (\(controllers.count) open)")
        StoreRegistry.shared.release(controller.projectKey)
        rememberOpenProjects()
    }

    /// Reopen what was open last time. A regular app that launches with no window at all reads as
    /// broken, so anything that leaves us with nothing — restore turned off, a first run, a stale list
    /// — falls back to one window on the focused project.
    func restoreOnLaunch() {
        if WindowSettings.shared.restoreWindows {
            // Skip keys that no longer name a project — a renamed or deleted folder, or a bad key that
            // got saved — rather than reopening a window that can only show the empty state. Dropping
            // them here also cleans them out of the saved list on the next write.
            // One window per remembered entry, not one per distinct project: the list is a list of
            // windows, and a project you had open in two of them comes back in two.
            for key in WindowSettings.shared.openProjectKeys where PMFiles.projectName(fromKey: key) != nil {
                open(projectKey: key, reusingExistingWindow: false)
            }
        }
        guard !controllers.isEmpty else {
            openFocusedProject()
            Log.write("launch: opened a window on the focused project")
            return
        }
        Log.write("launch: restored \(controllers.count) window(s)")
        // Leave the focused project's window in front, so launching lands where the menubar points.
        if let focused = PMFiles.focusedProjectKey(),
           let controller = controllers.first(where: { $0.projectKey == focused }) {
            controller.show()
        }
    }

    private func rememberOpenProjects() {
        WindowSettings.shared.openProjectKeys = controllers.compactMap(\.projectKey)
    }

    // MARK: Broadcasts

    /// Refresh window titles/subtitles after a store change (the project's name or progress moved).
    func refreshTitles() {
        for controller in controllers { controller.applyTitle() }
    }
}
