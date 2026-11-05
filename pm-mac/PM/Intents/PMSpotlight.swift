import CoreSpotlight
import Foundation
import PmLib

/// Best-effort indexing of PM projects and their open tasks into CoreSpotlight so they surface in
/// Spotlight and the semantic search that powers the new Siri. `indexAppEntities` (macOS 15+) links
/// each hit back to its App Intents entity; older systems, which predate that Siri, are a no-op.
///
/// Reindex is called on launch and after content-mutating intents. It fully replaces the app's index
/// each time — the dataset (active projects and their open tasks) is small enough that a full rebuild
/// is simpler and safer than tracking incremental deltas.
enum PMSpotlight {
    static func reindex() {
        guard #available(macOS 15.0, *) else { return }
        Task.detached(priority: .utility) { await reindexEntities() }
    }

    @available(macOS 15.0, *)
    private static func reindexEntities() async {
        do {
            let projects = try ProjectEntity.all()
            let tasks = projects.flatMap { p in (try? openTasks(of: p)) ?? [] }
            let index = CSSearchableIndex.default()
            try await index.deleteAllSearchableItems()
            if !projects.isEmpty { try await index.indexAppEntities(projects) }
            if !tasks.isEmpty { try await index.indexAppEntities(tasks) }
        } catch {
            // Indexing is a convenience; never let a Spotlight failure surface to the user.
        }
    }

    /// A project's open tasks, or none for a project whose notes are only in the cloud: reading them
    /// would download every such project's notes at each launch, for an index nobody asked to update.
    /// They are indexed the first reindex after the file is on this Mac.
    @available(macOS 15.0, *)
    private static func openTasks(of project: ProjectEntity) throws -> [TaskEntity] {
        let handle = try resolveNotesHandle(project: project.folder)
        guard !CloudFile.isCloudOnly(URL(fileURLWithPath: handle.notesPath)) else { return [] }
        return try notesShow(handle: handle).todos
            .filter { !$0.checked }
            .map { TaskEntity.make(projectKey: project.id, folder: project.folder, todo: $0) }
    }
}
