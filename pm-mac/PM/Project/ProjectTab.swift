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
enum ProjectTabView: Codable, Equatable, Hashable {
    /// The project's notes and tasks — the window's original shape, and still the default.
    case notes
    /// The project's board, whole or narrowed to a part of it.
    case board(CanvasFocus)

    var isBoard: Bool { if case .board = self { return true }; return false }

    /// The workspace this is a view of, or nil for the three tabs that are not one.
    ///
    /// **Total over workspaces, because every workspace has a name.** It used to be able to answer nil
    /// for a board that was tiled — the untitled workspace — and that case is gone: a set of tiles is a
    /// workspace, a workspace has a name, and the name is what a tab points at. See
    /// `ProjectTabSet.include(workspaces:)`.
    var workspaceName: String? {
        if case .board(.workspace(let name)) = self { return name }
        return nil
    }

    /// The canvas: the board itself, untiled.
    ///
    /// **Every window has exactly one of these and it is always the first tab** — see
    /// `ProjectTabSet`. It is the view a workspace is a narrowing *of*, so it is the one tab that
    /// cannot be closed, cannot be dragged out of first place, and is never tiled.
    var isCanvas: Bool { self == .board(.whole) }
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
enum CanvasFocus: Codable, Equatable, Hashable {
    /// The whole board, as the file describes it — **the canvas**, and the one focus that is never
    /// tiled. Every window has exactly one tab on it, first in the row. See `ProjectTabView.isCanvas`.
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

    /// A window that has never been given tabs: the canvas, plus `view` if that is something else.
    init(_ view: ProjectTabView = .notes) {
        let canvas = ProjectTab(.board(.whole))
        tabs = [canvas]
        selectedID = canvas.id
        guard !view.isCanvas else { return }
        let tab = ProjectTab(view)
        tabs.append(tab)
        selectedID = tab.id
    }

    /// Rebuilt from storage, and **made to hold the canvas** — which a row written before the canvas
    /// was permanent will not.
    ///
    /// A stored set that has lost its tabs, or whose selection names a tab that isn't there, is
    /// repaired rather than trusted: a window with no tab is a window with nothing in it, and there is
    /// no version of that worth showing somebody.
    init(tabs: [ProjectTab], selectedID: String?) {
        self.tabs = tabs
        self.selectedID = selectedID ?? ""
        seatTheCanvas()
        self.selectedID = self.tabs.contains { $0.id == selectedID } ? selectedID! : self.tabs[0].id
    }

    /// Put the canvas at the head of the row, making one if there isn't one.
    ///
    /// **The invariant, in one place.** Every mutation that could break it — a restore from a row
    /// written before this, a drag, a close — comes back through here rather than each re-deriving what
    /// "first" means. A second canvas tab is dropped for §7c's reason: two chips on one thing are two
    /// names for it.
    private mutating func seatTheCanvas() {
        var canvas: ProjectTab?
        tabs = tabs.filter { tab in
            guard tab.view.isCanvas else { return true }
            canvas = canvas ?? tab
            return false
        }
        tabs.insert(canvas ?? ProjectTab(.board(.whole)), at: 0)
    }

    /// The canvas tab, which every window has.
    var canvasID: String { tabs[0].id }

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

    /// **The row is the project's workspaces.** Put a chip on every one that hasn't got a chip, and
    /// take the chip off any that has stopped existing.
    ///
    /// A tab is where a workspace lives (docs/canvas-workspaces.md §7c), and once every workspace has a
    /// name that stops being a rule about the ones you happened to leave open and becomes the whole
    /// correspondence: a workspace *is* a chip and a chip is a workspace. There is nothing left for a
    /// "you closed this one" list to record, which is why the one that used to be here is gone — a
    /// workspace you do not want is deleted, from the chip's own menu, and deleting it takes the chip.
    ///
    /// **Existing tabs keep their places and their order.** The row can be dragged into an order (§7c)
    /// and that order is the user's; newcomers land after it, in the alphabetical order
    /// `CanvasWorkspaces.names` hands over — which is the order you would look one up in.
    mutating func include(workspaces names: [String]) {
        let known = Set(names)
        for name in names where first(showing: .board(.workspace(name))) == nil {
            tabs.append(ProjectTab(.board(.workspace(name))))
        }
        // A workspace deleted in another window leaves a chip pointing at nothing. Dropped here rather
        // than left to resolve as the whole board, which would be a second canvas chip.
        drop { $0.view.workspaceName.map { !known.contains($0) } ?? false }
    }

    /// Take out every tab this says yes to, keeping the window on something.
    mutating func drop(where doomed: (ProjectTab) -> Bool) {
        let index = selectedIndex
        tabs.removeAll(where: doomed)
        seatTheCanvas()
        guard !tabs.contains(where: { $0.id == selectedID }) else { return }
        selectedID = tabs[min(index, tabs.count - 1)].id
    }

    /// Keep the first chip on each view and close the rest, reporting the ids that went.
    ///
    /// **Two chips on one thing are two names for it** (§7c), and `openTab` has always refused to make
    /// a second. `retarget` cannot refuse in the same way — it is how a tab *follows* its board, and
    /// the collision only appears afterwards: rename "Review" to "Dashboard" while Dashboard has a chip
    /// and both chips now say Dashboard; delete a workspace two tabs were in and both land on the whole
    /// board and both say Canvas. So the passes that retarget in bulk sweep up behind themselves here,
    /// rather than every one of them re-deriving what a duplicate is.
    ///
    /// The survivor is the leftmost, because the row has an order and it is the user's (§7c) — the
    /// chip that has been sitting in that place is the one they know. A selection on a chip that goes
    /// moves to the survivor, so the window is still showing what it was showing.
    @discardableResult
    mutating func collapseDuplicates() -> [String] {
        var survivors: [ProjectTabView: String] = [:]
        var kept: [ProjectTab] = []
        var closed: [String] = []
        for tab in tabs {
            if let survivor = survivors[tab.view] {
                closed.append(tab.id)
                if tab.id == selectedID { selectedID = survivor }
            } else {
                survivors[tab.view] = tab.id
                kept.append(tab)
            }
        }
        guard !closed.isEmpty else { return [] }
        tabs = kept
        return closed
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
    /// **One caller, and it is a rename.** A tab used to *follow* the board it was holding, which is
    /// what this was for; §7i settled that a tab is what it is and the window changes tabs instead. A
    /// workspace renamed is the one act where the thing a chip points at genuinely becomes something
    /// else without the chip having moved — see `ProjectSplitViewController.renameWorkspace(named:to:)`.
    mutating func retarget(_ id: String, to view: ProjectTabView) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].view != view else {
            return
        }
        tabs[index].view = view
    }

    /// Close a tab, and say whether there was one to close.
    ///
    /// **Two kinds of tab refuse.** The canvas is the view every other one is a narrowing of, so a
    /// window without it is a window with no way back to its own board. And a workspace's chip *is* the
    /// workspace (docs/canvas-workspaces.md §7i): closing one would leave a named thing in the store
    /// with nowhere to be, which is the state a "you closed this one" list used to exist to paper over.
    /// The way to be rid of a workspace is Delete, on its own menu, and Delete takes the chip with it.
    ///
    /// Closing the tab you are looking at selects **the one to its right**, falling back to the left at
    /// the end of the row. Right rather than left because the tabs to the right are the ones you opened
    /// from here, so it is the direction you were travelling.
    @discardableResult
    mutating func close(_ id: String) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }), closable(tabs[index]) else {
            return false
        }
        tabs.remove(at: index)
        guard id == selectedID else { return true }
        selectedID = tabs[min(index, tabs.count - 1)].id
        return true
    }

    /// Whether this tab has a Close at all — see `close`.
    func closable(_ tab: ProjectTab) -> Bool {
        !tab.view.isCanvas && tab.view.workspaceName == nil
    }

    mutating func select(_ id: String) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// Go to the tab at `index`, or to the last one when the row is shorter than that. ⌘1…⌘9, where
    /// ⌘9 asks for `Int.max` and means the last however many there are.
    mutating func select(at index: Int) {
        guard !tabs.isEmpty else { return }
        selectedID = tabs[min(max(0, index), tabs.count - 1)].id
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
    ///
    /// **The canvas holds its place at both ends** — it cannot be dragged, and nothing can be dropped
    /// in front of it. It is the row's fixed point, and a row whose fixed point moves is a row with two
    /// firsts.
    mutating func move(_ id: String, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }), from != 0 else { return }
        let to = min(max(1, index), tabs.count - 1)
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
        // The canvas and the notes is the default, so a project back in its plain shape is stored as
        // nothing at all rather than as a row saying "the usual".
        if set.tabs.count == 2, set.tabs[1].view == .notes {
            all[projectKey] = nil
        } else {
            all[projectKey] = try? JSONEncoder().encode(
                Stored(tabs: set.tabs, selectedID: set.selectedID))
        }
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }

    /// **Decodes rows written before the canvas was permanent and before `dismissed` went**, both by
    /// ignoring what it does not know: a stored `dismissed` array is simply not read any more, and a
    /// row with no canvas tab in it is given one by `ProjectTabSet.init(tabs:selectedID:)`. Neither is
    /// worth a migration — the first is a list nothing can act on now, and the second is one insert.
    private struct Stored: Codable {
        var tabs: [ProjectTab]
        var selectedID: String
    }

    private static let defaultsKey = "PMProjectTabs"

    private static func stored() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }
}
