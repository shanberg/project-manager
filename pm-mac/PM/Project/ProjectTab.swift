import Foundation

/// One tab in a project window: one way of looking at one project.
///
/// **A window used to be a project**, and the app said so in five agreeing places — `WindowManager`
/// brought an open window forward rather than opening a second on the same project, `retarget` refused
/// outright because "two windows on one project would show the same store twice with nothing to tell
/// them apart", ⌘T opened the *next* project because a second tab on this one would be a duplicate,
/// the list of open windows was a list of project keys with no room for two, and both view memories
/// held exactly one answer per project and per file.
///
/// Every one of those was right while a project had one shape. It has several: its notes, its board,
/// a frame on that board, an arrangement of it. A tab is which of those you are looking at — which is
/// precisely the thing `retarget` said was missing.
struct ProjectTab: Codable, Equatable, Identifiable {
    /// Stable for the life of the tab, so the bar can animate a reorder and the selection can be stored
    /// as something other than an index. An index would be the wrong name for a tab the moment one to
    /// its left is closed.
    let id: String
    var view: ProjectTabView

    init(_ view: ProjectTabView, id: String = UUID().uuidString) {
        self.id = id
        self.view = view
    }
}

/// What a tab shows.
enum ProjectTabView: Codable, Equatable {
    /// The project's notes and tasks — the window's original shape, and still the default.
    case notes
    /// The project's board, whole or narrowed to a part of it.
    case board(CanvasFocus)

    var isBoard: Bool { if case .board = self { return true }; return false }
}

/// Which part of a board a tab is pinned to.
///
/// **Both of the narrowed cases name something that already exists and is already named**, which is
/// what keeps this from needing a naming UI of its own. A frame is a labelled container of cards on the
/// board, which ⌃1…9 goes to. A workspace is a tiling you named, and naming it is what kept it.
///
/// The two are different kinds of thing and used to share a word — see docs/canvas-workspaces.md §7.
/// A frame has a position and lives in the `.canvas`; a workspace has no position at all and never
/// touches the file. What they have in common is being a named set of cards, and that is the entire
/// overlap.
enum CanvasFocus: Codable, Equatable {
    /// The whole board, as the file describes it.
    case whole
    /// A frame, by node id. The id rather than the label, because a frame you rename is the same frame
    /// and a tab pointed at it should follow rather than break.
    case frame(String)
    /// The project's own card, tiled alone — the note-only view.
    ///
    /// **A way of looking, not a thing on the board.** The other two narrowed cases point at something
    /// the document names; this one points at the project, and the card is wherever the card is (or is
    /// put back if it has been taken off). It is a workspace of one card that nobody had to name,
    /// which is what the project window's notes turned out to be — see docs/canvas-workspaces.md §7d.
    case note
    /// A named workspace, by its name. The name *is* the identity here — there is nothing else to point
    /// at — so renaming one is making a different workspace, which is the honest answer for a thing
    /// whose whole content is a list of card ids and some widths.
    case workspace(String)

    /// **`workspace` goes on the wire as `arrangement`, and must keep doing so.**
    ///
    /// Swift synthesizes an enum's `Codable` from its *case names*, so this case has been encoding the
    /// literal word `arrangement` into every stored tab since tabs existed (`ProjectTabMemory`).
    /// Renaming the case without this would not fail loudly: the tab would decode as nothing, and a
    /// window somebody set up weeks ago would quietly come back one tab short. The word people read is
    /// worth changing; the word on disk is worth nothing, and changing it costs their tabs.
    enum CodingKeys: String, CodingKey {
        case whole
        case frame
        case note
        case workspace = "arrangement"
    }
}

// MARK: - The tabs a window is holding

/// A project window's tabs, and which one is up.
///
/// Value semantics and no views in sight, so the interesting part — what closing the tab you are
/// looking at selects next, what a reorder does to the selection — is arithmetic that can be tested
/// without a window.
struct ProjectTabSet: Codable, Equatable {
    private(set) var tabs: [ProjectTab]
    /// The tab showing. Held as an id rather than an index for the reason `ProjectTab.id` exists.
    private(set) var selectedID: String

    /// A window that has never been given tabs: one, showing `view`.
    init(_ view: ProjectTabView = .notes) {
        let tab = ProjectTab(view)
        tabs = [tab]
        selectedID = tab.id
    }

    /// Rebuilt from storage. A stored set that has somehow lost its tabs, or whose selection names a
    /// tab that isn't there, is repaired rather than trusted — a window with no tab is a window with
    /// nothing in it, and there is no version of that worth showing somebody.
    init(tabs: [ProjectTab], selectedID: String?) {
        guard !tabs.isEmpty else { self = ProjectTabSet(); return }
        self.tabs = tabs
        self.selectedID = tabs.contains { $0.id == selectedID } ? selectedID! : tabs[0].id
    }

    var selected: ProjectTab { tabs.first { $0.id == selectedID } ?? tabs[0] }
    var selectedIndex: Int { tabs.firstIndex { $0.id == selectedID } ?? 0 }

    /// Whether the window should draw a bar at all.
    ///
    /// One tab is no tabs: a window showing a project one way is what this app has always been, and a
    /// strip saying "1 of 1" above it is chrome that has nothing to report. Every Mac app with tabs
    /// hides the bar at one, and the header this bar lives in has a stronger reason than convention —
    /// see `ProjectTabBar`.
    var showsBar: Bool { tabs.count > 1 }

    // MARK: Changing them

    /// Open `view` in a new tab and go to it.
    ///
    /// **Immediately after the current tab**, not at the end. A tab you opened from the one you are in
    /// — a frame from its board, the notes from beside them — is related to it, and putting it at the
    /// far end of the bar throws that away. This is what every browser does with a link opened in a
    /// tab, and for the same reason.
    @discardableResult
    mutating func open(_ view: ProjectTabView) -> ProjectTab {
        let tab = ProjectTab(view)
        tabs.insert(tab, at: selectedIndex + 1)
        selectedID = tab.id
        return tab
    }

    /// Show `view` in the tab that is up, rather than in a new one.
    ///
    /// What the renderer switch does. A tab is a slot, not a fixed thing: pressing Tasks while looking
    /// at a board turns *this* view into the notes, exactly as following a link in a browser tab
    /// changes what that tab holds. Opening another is a different gesture and has its own.
    mutating func replaceSelected(with view: ProjectTabView) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        tabs[index].view = view
    }

    /// Open `view` *behind* the tab that is up, without going to it.
    ///
    /// **What ⌘Return does with the workspace it leaves.** Starting a fresh unnamed workspace does not
    /// discard the named one you were in — it is still in the durable store, and under
    /// docs/canvas-workspaces.md §7c the honest place for a workspace that still exists is a chip. So
    /// the one being left keeps a tab and the fresh one keeps the pane, which is the only way round
    /// that works: the pane in front of you is the one holding the selection ⌘Return acted on.
    ///
    /// Before rather than after, so the row reads in the order the two were made.
    mutating func openBehind(_ view: ProjectTabView) {
        tabs.insert(ProjectTab(view), at: selectedIndex)
    }

    /// The first tab showing exactly this, if one is open.
    ///
    /// **Switching goes to the tab a thing is already in rather than opening a second.** Two chips on
    /// one workspace are two names for one thing, and picking between them is a question with no
    /// answer — the same reason `WindowManager` brings a window forward instead of opening another on
    /// the project it already has.
    func first(showing view: ProjectTabView) -> ProjectTab? {
        tabs.first { $0.view == view }
    }

    /// Point an existing tab at something else, leaving the row and the selection alone.
    ///
    /// Not `replaceSelected`: this is how a tab *follows* the board it is holding — you named the
    /// workspace it was showing, or ⌘Return took it out of one — rather than how a tab is sent
    /// somewhere. See `ProjectSplitViewController.reconcileWorkspacePins`.
    mutating func retarget(_ id: String, to view: ProjectTabView) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].view != view else {
            return
        }
        tabs[index].view = view
    }

    /// Close a tab. The last one never closes — closing it is closing the window, which is the window's
    /// decision and not this type's.
    ///
    /// Closing the tab you are looking at selects **the one to its right**, falling back to the left at
    /// the end of the row. Right rather than left because the tabs to the right are the ones you opened
    /// from here, so it is the direction you were travelling.
    @discardableResult
    mutating func close(_ id: String) -> Bool {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        tabs.remove(at: index)
        guard id == selectedID else { return true }
        selectedID = tabs[min(index, tabs.count - 1)].id
        return true
    }

    mutating func select(_ id: String) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// ⌃⇥ and ⌃⇧⇥. Wraps, because a row of tabs has no end you should be stopped at.
    mutating func selectNext(by step: Int = 1) {
        guard tabs.count > 1 else { return }
        let next = (selectedIndex + step % tabs.count + tabs.count) % tabs.count
        selectedID = tabs[next].id
    }

    /// Take a tab out of the row and put it back at `index` — what a drag along the bar does.
    ///
    /// The same operation, spelled the same way, as `CanvasTileSession.move`: this is "that one goes
    /// *there*", which is what builds an order, rather than a swap, which only corrects one.
    mutating func move(_ id: String, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(0, index), tabs.count - 1)
        guard to != from else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
    }
}

// MARK: - Where they are kept

/// The tabs each project was last being looked at through.
///
/// **Per project, for the reason `ProjectRendererMemory` is** — and it supersedes that memory rather
/// than sitting beside it, because "which renderer" was only ever the one-tab version of this question
/// and two stores answering it would eventually disagree.
///
/// The old memory is not read from here, though, and that is deliberate: this file has to compile on
/// its own to be testable (see the note on the `PMViewTests` target), and a migration is edge work
/// anyway. The window passes what the old key said as `seed`, once, and from then on this owns the
/// answer.
///
/// In defaults rather than in the project's folder, unchanged from the reasoning `CanvasViewMemory`
/// sets out: how somebody had a window arranged on this Mac is not a fact about the project, and it has
/// no business in a vault that syncs.
enum ProjectTabMemory {
    /// What this project was last showing, or a single tab on `seed` when it has never been stored.
    static func of(_ projectKey: String?, seed: ProjectTabView = .notes) -> ProjectTabSet {
        guard let projectKey else { return ProjectTabSet(seed) }
        guard let data = stored()[projectKey],
              let saved = try? JSONDecoder().decode(Stored.self, from: data)
        else { return ProjectTabSet(seed) }
        return ProjectTabSet(tabs: saved.tabs, selectedID: saved.selectedID)
    }

    static func remember(_ set: ProjectTabSet, for projectKey: String?) {
        guard let projectKey else { return }
        var all = stored()
        // One tab on the notes is the default, so a project back in its plain shape is stored as
        // nothing at all rather than as a row saying "the usual".
        if set.tabs.count == 1, set.tabs[0].view == .notes {
            all[projectKey] = nil
        } else {
            all[projectKey] = try? JSONEncoder().encode(Stored(tabs: set.tabs,
                                                               selectedID: set.selectedID))
        }
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }

    private struct Stored: Codable {
        var tabs: [ProjectTab]
        var selectedID: String
    }

    private static let defaultsKey = "PMProjectTabs"

    private static func stored() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }
}
