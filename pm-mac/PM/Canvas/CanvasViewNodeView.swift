import AppKit
import PmLib
import SwiftUI

/// A view card on a board: a text node carrying `pmView`, drawn as the answer it names rather than as
/// its text (docs/views.md D3). See `CanvasViewSpec`.
///
/// **Reading only, for now.** Stepping in lets you scroll it and go to a project from its chip; ticking,
/// picking up and editing from a view are the next step (D6), and arrive through `StoreRegistry`
/// acquired on the act rather than held for every project in view.
final class CanvasViewNodeView: CanvasNodeView {
    let model: CanvasDayModel

    override init(node: CanvasNode, board: CanvasBoardView, scale: Double) {
        model = CanvasDayModel(spec: CanvasViewSpec.of(node) ?? .newDay)
        super.init(node: node, board: board, scale: scale)
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
            CanvasDayCard(model: model, zoom: contentZoom) { folder in
                WindowManager.shared.open(named: folder)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        )
        view.setAccessibilityLabel(accessibilityFallback)
        setContent(view)
    }

    override var scrollsItsContent: Bool { true }
    override var zoomsItsContent: Bool { true }
    override func contentZoomChanged() { contentChanged() }

    /// There's nothing here to type into. Stepping in is for scrolling and the chips, which a rebuild
    /// would only interrupt.
    override func engagementChanged() {}

    override var accessibilityFallback: String {
        let summary = model.summary
        return summary.isEmpty ? "\(model.spec.period.title) view" : "\(model.spec.period.title): \(summary)"
    }

    override func prepareForRemoval() {
        model.stop()
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
