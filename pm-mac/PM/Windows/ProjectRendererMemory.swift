import Foundation

/// Which way each project was last being looked at — its task list, or its board.
///
/// **Per project, and this used to be per window on purpose.** The argument against was that a window
/// walking down the sidebar would change shape under you, and it is a real cost: retargeting a window
/// to a project you last had as a board turns the task list into a canvas, and lifts the window's width
/// cap with it. What outweighs it is that the two renderers are not two ways of looking at the same
/// thing so much as two different projects' natural shapes. A project that is a board is a board every
/// time you open it, and being handed its task list instead — after a relaunch, or on the way back
/// round the sidebar — means doing the same switch again every time.
///
/// In defaults rather than in the project's folder, for the same reason as `CanvasViewMemory`: it is a
/// per-machine preference about a window, and somebody's notes are not the place for it.
enum ProjectRendererMemory {
    static func of(_ projectKey: String?) -> ProjectRenderer {
        guard let projectKey, let raw = stored()[projectKey] else { return .tasks }
        return ProjectRenderer(rawValue: raw) ?? .tasks
    }

    static func remember(_ renderer: ProjectRenderer, for projectKey: String?) {
        guard let projectKey else { return }
        var all = stored()
        // Tasks is the default, so a project that is back on its task list is a project with nothing
        // to say rather than a row saying "the usual".
        all[projectKey] = renderer == .tasks ? nil : renderer.rawValue
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }

    private static let defaultsKey = "PMProjectRenderer"

    private static func stored() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }
}
