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

    func show(_ child: NSViewController) {
        guard current !== child else { return }
        if let current {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        current = child
    }
}

/// What a project window shows in that column.
enum ProjectRenderer: String {
    case tasks, canvas
}

/// What the content column shows for a project that hasn't got a canvas yet.
///
/// Switching a *view* must not write to disk, which is the whole reason this exists. The app's other
/// route to a project's board — File ▸ Project Canvas, and the header's button — creates the file as a
/// side effect of asking for it, and that is right there: you asked for the board, so you get one. Here
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
