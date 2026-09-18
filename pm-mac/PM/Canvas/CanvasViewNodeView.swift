import AppKit
import PmLib
import SwiftUI

/// A view card on a board: a text node carrying `pmView`, drawn as the answer it names rather than as
/// its text (docs/views.md D3). See `CanvasViewSpec`.
///
/// **A place you work** (D6). A row ticks, drops, picks up and retypes the way the same row does on a
/// project card, through its own project's store — taken when you act, not for every project in view.
/// See `CanvasDayActions`.
final class CanvasViewNodeView: CanvasNodeView {
    let model: CanvasDayModel
    let actions: CanvasDayActions

    override init(node: CanvasNode, board: CanvasBoardView, scale: Double) {
        model = CanvasDayModel(spec: CanvasViewSpec.of(node) ?? .newDay)
        actions = CanvasDayActions { ProjectIndex.shared.projectKey(forFolder: $0) }
        super.init(node: node, board: board, scale: scale)
        // The act is now the thing ⌘Z takes back — `CanvasUndoRoute`'s project route, as a tick on a
        // project card is.
        actions.onActed = { [weak self] store in self?.board.lastEditedProject = store }
        model.boardProjects = boardProjectFolders()
        model.onChange = { [weak self] in
            // The zoomed-out face is one label, built from the summary rather than observing it.
            guard let self, self.isSimplified else { return }
            self.contentChanged()
            self.refreshAccessibility()
        }
        model.start()
        contentChanged()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The node's settings live in `extra`, which the base class doesn't watch; a change there is a new
    /// question for the same card, not a rebuild. The board's own project cards are read again on every
    /// pass too, since a card set to this board's projects follows the board.
    override func update(node: CanvasNode, scale: Double) {
        super.update(node: node, scale: scale)
        if let spec = CanvasViewSpec.of(node), spec != model.spec { model.spec = spec }
        if model.spec.projects == .board {
            let folders = boardProjectFolders()
            if folders != model.boardProjects { model.boardProjects = folders }
        }
    }

    override func contentChanged() {
        if isSimplified {
            let summary = model.summary
            return setContent(summaryView(summary.isEmpty ? model.spec.period.title : "\(model.spec.period.title): \(summary)",
                                          symbol: "calendar"))
        }
        let view = NSHostingView(rootView:
            CanvasDayCard(model: model, zoom: contentZoom,
                          onOpenProject: { folder in WindowManager.shared.open(named: folder) },
                          onAct: { [weak self] act, rows, sitting in
                              guard let self else { return }
                              self.actions.perform(act, on: rows, inProject: sitting.projectFolder) { [weak self] in
                                  for row in rows { self?.model.settle(CanvasDayRows.key(row, in: sitting)) }
                              }
                          },
                          sittingCard: { [weak self] sitting in self?.sittingCardProvider(sitting) })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        )
        view.setAccessibilityLabel(accessibilityFallback)
        setContent(view)
    }

    override var scrollsItsContent: Bool { true }
    override var zoomsItsContent: Bool { true }
    override func contentZoomChanged() { contentChanged() }

    /// A row takes its own click, as a project card's does: the box ticks on the first one.
    override var engagesOnClick: Bool { !isSimplified }

    /// Stepping in hands the keyboard to the card, for a row being retyped; stepping out takes it back.
    /// Nothing is rebuilt, which would only interrupt the scroll.
    override func engagementChanged() {
        model.isEngaged = isEngaged
        if !isEngaged { model.selection.clear() }
        guard let content = subviews.first else { return }
        if isEngaged {
            window?.makeFirstResponder(content)
        } else if (window?.firstResponder as? NSView)?.isDescendant(of: content) == true {
            window?.makeFirstResponder(board)
        }
    }

    override var accessibilityFallback: String {
        let summary = model.summary
        return summary.isEmpty ? "\(model.spec.period.title) view" : "\(model.spec.period.title): \(summary)"
    }

    override func prepareForRemoval() {
        model.stop()
        if let store = board.lastEditedProject,
           actions.heldStores.contains(where: { $0 === store }) { board.lastEditedProject = nil }
        actions.releaseAll()
    }

    /// What a sitting dragged off this card carries: a project card of that one sitting (docs/views.md
    /// D7), in the board's own clipping flavour, so the board makes exactly that card where it lands —
    /// and its name as text for anywhere else.
    private func sittingCardProvider(_ sitting: SittingEntry) -> NSItemProvider? {
        guard let document = CanvasSittingPin.card(for: sitting, resolver: board.store.resolver) else { return nil }
        let data = Data(document.serialized().utf8)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: CanvasClipping.pasteboardType.rawValue,
                                            visibility: .ownProcess) { done in
            done(data, nil)
            return nil
        }
        let title = [sitting.projectName, sitting.name].filter { !$0.isEmpty }.joined(separator: " — ")
        provider.registerObject(title as NSString, visibility: .all)
        return provider
    }

    /// The file paths on the board when `boardProjectFolders` last resolved them. `update` runs on every
    /// layout pass — every frame of a zoom flight — and resolving a path can touch the disk, so the
    /// answer is kept until the board's files change.
    private var resolvedPaths: [String]?
    private var resolvedFolders: [String] = []

    /// The folders of the projects with a card on this board — the project notes cards, by where their
    /// file is.
    private func boardProjectFolders() -> [String] {
        let paths = board.document.nodes.compactMap { node -> String? in
            if case .file(let path, _) = node.content { return path }
            return nil
        }
        if paths == resolvedPaths { return resolvedFolders }
        var folders: [String] = []
        for path in paths {
            guard let url = board.store.resolver.resolve(path).url,
                  let folder = projectFolder(ofNotesPath: url.path) else { continue }
            let name = (folder as NSString).lastPathComponent
            if !folders.contains(name) { folders.append(name) }
        }
        resolvedPaths = paths
        resolvedFolders = folders.sorted()
        return resolvedFolders
    }
}
