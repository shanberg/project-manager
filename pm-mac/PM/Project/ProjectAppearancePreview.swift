import AppKit
import Observation
import PmLib

/// What Project Settings has chosen and not yet saved, shown in the project's windows as it's chosen.
///
/// Colour and texture are judged by eye against the window they're for, so the sheet doesn't make you
/// save to see them: every change is published here, keyed by the project's folder name, and a project
/// window draws its board from here rather than from its store while there's an entry for it — see
/// `ProjectSplitViewController.projectColorChanged`.
///
/// **Cancel** takes the entry away, and the window goes back to what's saved. **Save** leaves it up
/// until the store has read the file back, since taking it away at once would flash the old look for
/// the moment between the write and the read.
@MainActor
@Observable
final class ProjectAppearancePreview {
    static let shared = ProjectAppearancePreview()

    struct Appearance: Equatable {
        var color: ProjectColor?
        var texture: CanvasTexture.Spec?
        /// Saved: waiting for the store to catch up, and no longer the sheet's to change.
        var isCommitted = false
    }

    private(set) var byProject: [String: Appearance] = [:]

    func show(_ appearance: Appearance, for project: String) {
        byProject[project] = appearance
    }

    func cancel(for project: String) {
        byProject[project] = nil
    }

    /// Hand over to the store: the entry goes when a window sees the store say the same thing, or after
    /// `settle` if nothing ever does — a save that changed nothing, or a rename that moved the key.
    func commit(for project: String) {
        guard byProject[project] != nil else { return }
        byProject[project]?.isCommitted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle) { [weak self] in
            if self?.byProject[project]?.isCommitted == true { self?.byProject[project] = nil }
        }
    }

    /// A window's store has caught up with a saved entry; the entry can go.
    func settled(for project: String) {
        if byProject[project]?.isCommitted == true { byProject[project] = nil }
    }

    static let settle: TimeInterval = 3
}

/// The dimming AppKit lays over a window while it has a sheet — which is exactly what's in the way when
/// the sheet is for choosing how that window looks.
///
/// There's no public switch. On macOS 27 it's an `NSSheetEffectDimmingView` in the window's frame
/// view, added when the sheet begins and removed when it ends. Faded out, then hidden: AppKit puts
/// its alpha back on the next resize or activation, but leaves `isHidden` alone, and still takes the
/// view away itself when the sheet ends. If a later macOS draws it some other way, this finds nothing
/// and the dimming simply stays.
@MainActor
enum SheetDimming {
    static func reveal(_ window: NSWindow) {
        guard let frame = window.contentView?.superview else { return }
        let dimmers = frame.subviews.filter {
            !$0.isHidden && String(describing: type(of: $0)) == "NSSheetEffectDimmingView"
        }
        guard !dimmers.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            dimmers.forEach { $0.animator().alphaValue = 0 }
        } completionHandler: {
            dimmers.forEach { $0.isHidden = true }
        }
    }
}
