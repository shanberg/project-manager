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
        let view = NSView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        self.view = view
    }

    /// What this tab has already built, if anything.
    func content(for tab: String) -> NSViewController? { mounted[tab] }

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

/// What the content column shows for a project that hasn't got a canvas yet.
///
/// Switching a *view* must not write to disk, which is the whole reason this exists. The app's other
/// route to a project's board — File ▸ Open Project Canvas in New Window, and this state's own button —
/// creates the file as a side effect of asking for it, and that is right there: you asked for the board,
/// so you get one. Here
/// you asked to look at the window differently, and answering that by creating a file in somebody's
/// vault is a decision the request didn't contain.
struct ProjectCanvasEmptyState: View {
    var projectName: String?
    var create: () -> Void
    var showTasks: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 5) {
                Text(projectName.map { "\($0) has no canvas yet." } ?? "No project.")
                    .font(.headline)
                Text("A canvas is an Obsidian board in the project\u{2019}s folder. "
                     + "PM will make an empty one and open it here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            if projectName != nil {
                HStack(spacing: 10) {
                    Button("Back to Tasks", action: showTasks)
                    Button("Create Canvas", action: create)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
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
