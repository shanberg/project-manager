import AppKit
import PmLib

/// Every command PM offers on a project or on the task in hand, declared once.
///
/// This exists because the same command used to be declared three times — in `MainMenu`, in
/// `StatusItemController`'s submenus, and in the quick bar's `>` list — and the three had drifted in
/// all the ways parallel lists drift. Coverage: eleven commands the menu extra and the quick bar
/// offered were absent from the menu bar entirely, which inverted the one rule macOS has here — the
/// menu bar is the complete command model and every other surface is a shortcut into it. Naming: the
/// same action was "Undo Last Completion" in one place and "Undo Last Complete" in another, and
/// "Reveal Project in Finder" in the menu bar was the identical call as "Open in Finder" in the menu
/// extra. Availability: three separate answers to "can this run right now".
///
/// So this table owns **identity, placement and availability**. It deliberately does not own
/// execution: the two menus act on the focused project's store and share `PMCommandRunner`, while the
/// quick bar runs its own version because it has an argument to pass, a preview to draw and a receipt
/// to give — none of which a menu has. What was drifting was the names and the coverage, not the
/// plumbing.
enum PMCommand: String, CaseIterable, Identifiable {
    // The task in hand.
    case complete
    case undoLast
    case diveIn
    case narrowFocus
    case addAfter
    case addBefore
    case editTask
    case setDue
    case wrapTask

    // The session.
    case startSession
    case sessionNote

    // The project.
    case openWindow
    case openInFinder
    case openInObsidian
    case openInEditor
    case editDetails
    case addLink
    case renameProject
    case archiveProject
    case unarchiveProject

    // The app. Placed in the File menu by hand — see `menuSection` — but named here so the quick bar
    // and the menu bar can't come to call them different things.
    case newProject
    case settings

    var id: String { rawValue }

    // MARK: Identity

    /// The command's one name, in every surface that offers it.
    ///
    /// Ellipses follow the Mac convention rather than the surface: a command that opens an editor,
    /// a prompt or a form to finish the job takes one; a command that just happens is bare. That's
    /// why Complete and Dive In have none and Rename Project does.
    var title: String {
        switch self {
        case .complete: return "Complete Focused Task"
        case .undoLast: return "Undo Last Completion"
        case .diveIn: return "Dive In"
        case .narrowFocus: return "Narrow Focus…"
        case .addAfter: return "Add Task After…"
        case .addBefore: return "Add Task Before…"
        case .editTask: return "Edit Focused Task…"
        case .setDue: return "Set Due Date…"
        case .wrapTask: return "Wrap Focused Task…"
        case .startSession: return "Start Today's Session"
        case .sessionNote: return "Add Session Note…"
        case .openWindow: return "Open Project Window"
        // "Reveal", not "Open". The call is `activateFileViewerSelecting`, which selects the folder in
        // its parent rather than opening it — and "Reveal in Finder" is what every Mac app calls that.
        // The menu bar already said "Reveal Project in Finder" for this exact action while the menu
        // extra said "Open in Finder"; one of the two names had to go, and this is the accurate one.
        case .openInFinder: return "Reveal in Finder"
        case .openInObsidian: return "Open in Obsidian"
        case .openInEditor: return "Open in Editor"
        case .editDetails: return "Edit Project Details…"
        case .addLink: return "Add Link…"
        case .renameProject: return "Rename Project…"
        case .archiveProject: return "Archive Project"
        case .unarchiveProject: return "Unarchive Project"
        case .newProject: return "New Project…"
        case .settings: return "Settings…"
        }
    }

    /// The title as it should read given what's actually on screen. Only two commands have one: the
    /// editor names whichever app Settings picked, so the menu says "Open in Zed" rather than making
    /// you find out by pressing it.
    @MainActor
    func title(in context: Context) -> String {
        switch self {
        case .openInEditor:
            return context.editorName.map { "Open in \($0)" } ?? title
        default:
            return title
        }
    }

    var symbol: String {
        switch self {
        case .complete: return "checkmark.circle"
        case .undoLast: return "arrow.uturn.backward"
        case .diveIn: return "arrow.down.to.line"
        case .narrowFocus: return "arrow.turn.down.right"
        case .addAfter: return "arrow.down"
        case .addBefore: return "arrow.up"
        case .editTask: return "pencil"
        case .setDue: return "calendar"
        case .wrapTask: return "arrow.up.and.down.and.arrow.left.and.right"
        case .startSession: return "calendar.badge.plus"
        case .sessionNote: return "note.text"
        case .openWindow: return "macwindow"
        case .openInFinder: return "folder"
        case .openInObsidian: return "book.closed"
        case .openInEditor: return "chevron.left.forwardslash.chevron.right"
        case .editDetails: return "text.justify.left"
        case .addLink: return "link"
        case .renameProject: return "square.and.pencil"
        case .archiveProject: return "archivebox"
        case .unarchiveProject: return "arrow.up.bin"
        case .newProject: return "plus.square"
        case .settings: return "gearshape"
        }
    }

    // MARK: Placement

    /// Which menu-bar menu builds this item for itself.
    ///
    /// `.task` and `.project` are generated from this table, in declaration order, so a command added
    /// above appears in the menu bar without anyone remembering to add it. `nil` means the menu bar
    /// places it by hand: the File menu's items carry deliberate shortcuts and a deliberate order
    /// (three "new"s in scale order, the two ways of going somewhere side by side) that a generated
    /// list would flatten. They're still named here, because a name is the thing that drifts.
    enum MenuSection { case task, project }

    var menuSection: MenuSection? {
        switch self {
        case .complete, .undoLast, .diveIn, .narrowFocus, .addAfter, .addBefore,
             .editTask, .setDue, .wrapTask:
            return .task
        case .startSession, .sessionNote, .openWindow, .openInFinder, .openInObsidian, .openInEditor,
             .editDetails, .addLink, .renameProject, .archiveProject, .unarchiveProject:
            return .project
        case .newProject, .settings:
            return nil
        }
    }

    /// A separator is drawn *before* this item when its menu is built — the one piece of grouping a
    /// flat declaration order can't express on its own.
    var startsMenuGroup: Bool {
        switch self {
        case .diveIn, .narrowFocus, .setDue,             // Task: act, navigate, add around, schedule
             .openWindow, .editDetails, .renameProject:  // Project: open, edit, manage
            return true
        default:
            return false
        }
    }

    /// The key equivalent this command carries in the menu bar, for the few that have one.
    ///
    /// Deliberately short. A shortcut is a claim on the whole app's keyboard, and most of these are
    /// reached a few times a week from a menu that's already open.
    var keyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        switch self {
        case .complete: return ("\r", [.command, .shift])
        case .diveIn: return ("d", [.command, .shift])
        case .openInFinder: return ("r", [.command, .shift])
        default: return nil
        }
    }

    /// Whether the menu extra's dropdown offers this, and under which of its two submenus.
    ///
    /// The extra's shape isn't the menu bar's: it collapses the task editors into `Add ▸` and the rest
    /// into `Project ▸`, because it's a dropdown read at a glance rather than a menu bar browsed by
    /// name. Same commands, same names, grouped for the surface they're on.
    enum StatusMenuGroup { case add, project }

    var statusMenuGroup: StatusMenuGroup? {
        switch self {
        case .narrowFocus, .addAfter, .addBefore, .editTask, .setDue, .wrapTask:
            return .add
        case .openInFinder, .openInObsidian, .openInEditor, .openWindow, .renameProject,
             .sessionNote, .startSession, .addLink, .editDetails, .archiveProject, .unarchiveProject:
            return .project
        // Complete, Undo Last and Dive In sit inline at the top of the dropdown rather than in a
        // submenu — they're the reason the menu gets opened. The menu builds those itself.
        case .complete, .undoLast, .diveIn, .newProject, .settings:
            return nil
        }
    }

    /// `Add ▸` and `Project ▸` in declaration order, which is the order the menu bar uses too.
    static func statusMenu(_ group: StatusMenuGroup) -> [PMCommand] {
        allCases.filter { $0.statusMenuGroup == group }
    }

    static func menu(_ section: MenuSection) -> [PMCommand] {
        allCases.filter { $0.menuSection == section }
    }

    // MARK: The quick bar

    /// Whether `>` offers this.
    ///
    /// Three don't. Narrow Focus, Add After and Add Before are the quick bar's *capture* rows already
    /// — typing a line and choosing where it lands is the thing the bar is best at — so offering them
    /// again as commands that open an empty editor somewhere else would be two answers to one
    /// question, and the worse one.
    var inQuickBar: Bool {
        switch self {
        case .narrowFocus, .addAfter, .addBefore: return false
        // `>note` was a command that switched to a mode, in a list whose whole point is to be *not* a
        // mode — and it was a third way to put prose in today's note beside the surface it opened and
        // the capture row. The surface is reachable by ⌃⌥N, by ⇧⏎ out of a capture line, and now by ⇥
        // round the ring; that's enough ways in for something you can't get to by accident.
        case .sessionNote: return false
        default: return true
        }
    }

    static var quickBarCommands: [PMCommand] { allCases.filter(\.inQuickBar) }

    /// The single word that introduces this command's text, for the commands that take any.
    ///
    /// One word, and never shared between two commands, because this is what splits a typed line into
    /// a verb and its argument — `>note had a call with Dana`. Two commands answering to the same verb
    /// would make that split a guess, which is the thing that mode exists to avoid.
    var verb: String? {
        switch self {
        case .setDue: return "due"
        case .startSession: return "session"
        // No verb for `sessionNote`: it isn't offered in `>` at all — see `inQuickBar`.
        default: return nil
        }
    }

    /// What the text after the verb is for, shown as a placeholder in the row.
    var argumentLabel: String? {
        switch self {
        case .setDue: return "tomorrow, friday, in 2w…"
        case .startSession: return "a label for today"
        default: return nil
        }
    }

    /// Extra words this command answers to, beyond the ones in its title.
    var keywords: [String] {
        switch self {
        case .complete: return ["done", "check", "finish", "tick"]
        case .undoLast: return ["undo", "revert", "uncheck"]
        case .diveIn: return ["next", "deeper"]
        case .narrowFocus: return ["child", "under", "subtask"]
        case .addAfter: return ["sibling", "below"]
        case .addBefore: return ["above"]
        case .editTask: return ["retitle"]
        case .setDue: return ["due", "date", "defer", "schedule", "when"]
        case .wrapTask: return ["parent", "outdent"]
        case .startSession: return ["session", "today", "day"]
        case .sessionNote: return ["note", "log", "journal"]
        case .openWindow: return ["show"]
        case .openInFinder: return ["reveal", "folder", "files", "open"]
        case .openInObsidian: return ["notes", "markdown"]
        case .openInEditor: return ["code", "editor", "cursor", "vscode", "zed", "xcode"]
        case .editDetails: return ["summary", "problem", "goals", "approach", "learnings", "brief"]
        case .addLink: return ["url", "bookmark"]
        case .renameProject: return ["title"]
        case .archiveProject: return ["archive", "shelve", "done"]
        case .unarchiveProject: return ["unarchive", "restore", "reopen"]
        case .newProject: return ["create", "start"]
        case .settings: return ["preferences", "config", "shortcuts"]
        }
    }

    // MARK: Availability

    /// What a surface knows about the moment it's asking in. One answer to "can this run right now",
    /// so the menu bar's grey, the menu extra's grey and the quick bar's omission can't disagree.
    ///
    /// The cheap facts are stored; the two that touch the filesystem are computed on demand. A context
    /// is built once per menu *open* but consulted once per menu *item*, and eagerly resolving the
    /// archive path and the installed editor would have meant a config read and a LaunchServices
    /// lookup for every row of a menu — to answer a question only three of those rows ask.
    struct Context {
        var hasProject = false
        var hasFocusedTask = false
        var hasNextTask = false
        var canUndoCompletion = false
        var hasPath = false
        /// Nil for a surface that resolves these itself; set when the context was built from a store.
        var projectKey: String?
        var projectPath: String?

        /// Overrides for a surface that already knows, so it doesn't pay for the lookups: the quick
        /// bar reads archived-ness off its own model, which tracked it before this table existed.
        var isArchivedOverride: Bool?

        /// The context for whatever project is focused — what both menus ask against.
        @MainActor
        init(store: PMStore) {
            hasProject = store.projectName != nil
            hasFocusedTask = store.focusedTodo != nil
            hasNextTask = store.nextTodo != nil
            canUndoCompletion = store.lastCompletedKey != nil
            hasPath = store.projectPath != nil
            projectKey = store.projectKey
            projectPath = store.projectPath
        }

        /// For a surface that has the facts but not the store — the quick bar, which reads them off
        /// its own model.
        init() {}

        /// Archived or not is a question about where the folder lives, which the key already answers.
        @MainActor
        var isArchived: Bool {
            if let isArchivedOverride { return isArchivedOverride }
            return Self.isArchived(key: projectKey)
        }

        @MainActor
        static func isArchived(key: String?) -> Bool {
            guard let key else { return false }
            return (try? loadConfigAndPaths()).map { key.hasPrefix("\($0.1.archivePath):") } ?? false
        }

        /// Whether the focused project's folder is a repository — the test for "this is code".
        @MainActor
        var isCodeProject: Bool {
            guard let projectPath else { return false }
            return CodeEditor.isCodeProject(at: projectPath)
        }

        /// The editor Settings ▸ Projects names, when there is one. Also the title for `.openInEditor`.
        @MainActor
        var editorName: String? {
            CodeEditor.resolvedBundleID.map(CodeEditor.displayName)
        }
    }

    /// Whether this command has anything to act on. What can't run is greyed in a menu and left out of
    /// the quick bar's list — a command offered into a no-op is worse than one that isn't offered.
    @MainActor
    func isAvailable(in context: Context) -> Bool {
        switch self {
        case .newProject, .settings:
            return true
        case .complete, .editTask, .setDue, .wrapTask, .narrowFocus, .addAfter, .addBefore:
            return context.hasFocusedTask
        case .undoLast:
            return context.canUndoCompletion
        case .diveIn:
            return context.hasNextTask
        case .openInFinder:
            return context.hasPath
        case .openInEditor:
            return context.hasPath && context.isCodeProject && context.editorName != nil
        case .archiveProject:
            return context.hasProject && !context.isArchived
        case .unarchiveProject:
            return context.hasProject && context.isArchived
        default:
            return context.hasProject
        }
    }
}
