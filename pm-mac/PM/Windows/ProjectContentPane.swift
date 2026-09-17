import AppKit
import SwiftUI

/// The project window's content column, which is a container rather than a thing.
///
/// A project window can render its project two ways: the task list it has always shown, and the
/// project's own canvas. Both fill the same pane beside the same sidebar, under the same window frame,
/// so the split view item stays put and this swaps what is inside it. Swapping the item's own view
/// controller is not something `NSSplitViewItem` offers, and re-adding the item would lose the divider
/// position and the pane's safe-area arrangement along with it.
@MainActor
final class ProjectContentPaneController: NSViewController {
    private(set) var current: NSViewController?
    /// Every tab's content, by tab id, whether or not it is the one showing.
    ///
    /// **Kept mounted rather than rebuilt on every switch**, which is the difference between tabs and a
    /// switch with more positions. A board torn down and remade loses its scroll position, its zoom,
    /// its tiling and every page it had running, so flicking to the notes and back would cost what
    /// getting the board arranged had cost. The bounded thing here is renderers, not views, and the
    /// page budget already handles that: a hidden view has an empty `visibleRect`, so a background
    /// tab's cards read as off screen and give their pages up. See `CanvasBoardView.applyPageBudget`.
    private var mounted: [String: NSViewController] = [:]

    override func loadView() {
        // Layer-backed and masking, so the task column's push transitions — the session-note takeover
        // sliding in from the trailing edge while the list slides out the leading one — are contained
        // to the pane. The column used to do this with a SwiftUI `.clipped()`, which kept a scrolling
        // list inside a clip layer permanently for the sake of a quarter-second animation.
        let view = ProjectContentGround()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        self.view = view
    }

    /// What this tab has already built, if anything.
    func content(for tab: String) -> NSViewController? { mounted[tab] }
    /// Every tab's content that has been mounted, shown or hidden.
    var allContent: [NSViewController] { Array(mounted.values) }

    /// Put `child` on screen as `tab`'s content, adding it if this is the first time.
    ///
    /// Hidden rather than removed, so everything a tab had is still there when you come back to it.
    func show(_ child: NSViewController, for tab: String) {
        if mounted[tab] !== child {
            mounted[tab].map(drop)
            mounted[tab] = child
            addChild(child)
            child.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child.view)
            NSLayoutConstraint.activate([
                child.view.topAnchor.constraint(equalTo: view.topAnchor),
                child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        guard current !== child else { return }
        current?.view.isHidden = true
        child.view.isHidden = false
        // In front of the tabs behind it. Hidden views don't draw, but they do still sit in the
        // subview order, and a later-added tab would otherwise cover the one being shown.
        view.addSubview(child.view, positioned: .above, relativeTo: nil)
        current = child
        (current as? ProjectTabContent)?.paneBecameVisible()
    }

    /// Tear a tab's content down — it has been closed, or the window is going away.
    func drop(tab: String) {
        guard let child = mounted.removeValue(forKey: tab) else { return }
        if current === child { current = nil }
        drop(child)
    }

    func dropAll() {
        for (tab, _) in mounted { drop(tab: tab) }
    }

    private func drop(_ child: NSViewController) {
        (child as? ProjectTabContent)?.paneWillClose()
        child.view.removeFromSuperview()
        child.removeFromParent()
    }
}

/// The column's own ground — what the window shows where no pane is showing anything.
///
/// **There is such a moment, and it used to be a hole.** Pointing the window at another project drops
/// every pane the old one had and asks for the new project's board, whose path arrives with that
/// store's first read of the folder — a fresh store every time, since one only lives as long as a
/// window holds it (`StoreRegistry.acquire`). Until it lands the column holds an empty pane on
/// purpose; see `ProjectSplitViewController.retarget` and `makeBoardless`, which argue for waiting
/// rather than putting something on screen to take away again a moment later.
///
/// What it did not argue for is what waiting looked like. Nothing in the column was painting, and an
/// unpainted region of a layer-backed hierarchy in an opaque window is not the window's grey — it is
/// the backing behind it. So switching between two projects that were both showing a board flashed
/// black between them, for however long the folder took to read.
///
/// `CanvasPalette.board` rather than a grey of this view's own: a board *is* painted with the window's
/// background (see that comment, which is the whole argument for it), so the gap is now the same
/// colour as the boards either side of it and there is nothing left to see. Drawn rather than set on
/// the layer, so it follows the appearance, Increase Contrast and a tinted desktop the way every other
/// use of that colour does — a `CGColor` on a layer is resolved once, against whichever appearance
/// happened to be current when it was set.
private final class ProjectContentGround: NSView {
    override var isOpaque: Bool { true }

    override func draw(_ dirty: NSRect) {
        CanvasPalette.board.setFill()
        dirty.fill()
    }
}

/// What a pane wants to know about being put on screen or taken off it.
///
/// A board that has just come forward has to re-decide which of its cards deserve a live page — the
/// budget is settled on a timer and on scrolling, and neither of those happens to a tab you switched
/// away from ten minutes ago.
@MainActor
protocol ProjectTabContent: AnyObject {
    func paneBecameVisible()
    func paneWillClose()
}

/// What a project window shows in that column.
enum ProjectRenderer: String {
    case tasks, canvas
}

/// A pane with nothing in it, shown while a board tab is waiting to find out where its canvas is.
///
/// Deliberately empty — no spinner, no message. The wait is one asynchronous directory listing, over
/// in a few milliseconds on a warm vault, and anything drawn in it would be a thing that appears and
/// disappears for its own sake. What this is for is *not* putting the task list on screen for that
/// moment; see `ProjectSplitViewController.makeContent`.
@MainActor
final class ProjectWaitingPaneController: NSViewController {
    override func loadView() { view = NSView() }
}
