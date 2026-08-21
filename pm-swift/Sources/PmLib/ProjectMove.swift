import Foundation

/// Which of the two project folders a project lives in.
///
/// Archiving and unarchiving are the same operation in opposite directions — a folder move between
/// these two — so they're one function with a direction rather than two near-identical ones.
public enum ProjectScope: String, Codable, Sendable {
    case active
    case archive

    public var opposite: ProjectScope { self == .active ? .archive : .active }

    public func path(in paths: ResolvedPaths) -> String {
        self == .active ? paths.activePath : paths.archivePath
    }
}

/// Move a project folder from one scope to the other. Returns the folder's new path.
///
/// `folderName` is an exact folder name, not a query: callers that take a typed name (the CLI) match
/// it themselves so they can report ambiguity in their own terms, and callers that already have a
/// project in hand (the app) have nothing to match.
@discardableResult
public func moveProject(named folderName: String, from source: ProjectScope,
                        to destination: ProjectScope, paths: ResolvedPaths) throws -> String {
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
    try FileManager.default.moveItem(atPath: sourcePath, toPath: destinationPath)
    return destinationPath
}
