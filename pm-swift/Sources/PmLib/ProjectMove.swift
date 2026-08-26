import Foundation

/// Which of the PARA roots a folder lives in.
///
/// Archiving and unarchiving are the same operation in opposite directions — a folder move between
/// two of these — so they're one function with a direction rather than two near-identical ones.
///
/// There used to be an `opposite`, which worked while there were two scopes and stopped working the
/// moment there were three: everything archives *into* `archive`, but what comes back out goes to
/// `active` or to `areas` depending on what it is. That question is answered by the folder's own
/// name — see `ProjectKind.homeScope` — so it stays answerable for a folder that has been sitting in
/// the archive for a year.
public enum ProjectScope: String, Codable, Sendable, CaseIterable {
    case active
    case areas
    case archive

    /// Whether things here are put away rather than in hand.
    public var isArchived: Bool { self == .archive }

    public func path(in paths: ResolvedPaths) -> String {
        switch self {
        case .active: return paths.activePath
        case .areas: return paths.areasPath
        case .archive: return paths.archivePath
        }
    }
}

/// Move a project folder from one scope to the other. Returns the folder's new path.
///
/// `folderName` is an exact folder name, not a query: callers that take a typed name (the CLI) match
/// it themselves so they can report ambiguity in their own terms, and callers that already have a
/// project in hand (the app) have nothing to match.
/// - Parameter dryRun: make both existence checks and work out the destination, then stop before the
///   move — so a preview refuses exactly where the real call would.
@discardableResult
public func moveProject(named folderName: String, from source: ProjectScope,
                        to destination: ProjectScope, paths: ResolvedPaths,
                        dryRun: Bool = false) throws -> String {
    let sourcePath = (source.path(in: paths) as NSString).appendingPathComponent(folderName)
    let destinationPath = (destination.path(in: paths) as NSString).appendingPathComponent(folderName)

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: sourcePath, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        throw PmError.projectNotFound(folderName)
    }
    // Numbers are unique across both folders, so this normally can't happen — but a project restored
    // by hand, or a half-finished move, would leave one in both, and `moveItem` would fail with a
    // POSIX error that says nothing about projects.
    guard !FileManager.default.fileExists(atPath: destinationPath) else {
        throw PmError.moveTargetExists(destinationPath)
    }
    if dryRun { return destinationPath }
    try FileManager.default.moveItem(atPath: sourcePath, toPath: destinationPath)
    return destinationPath
}
