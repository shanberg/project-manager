import Foundation

public func createProject(config: PmConfig, paths: ResolvedPaths, domainCode: String, title: String) throws -> String {
    let formatted = try getNextFormattedNumber(activePath: paths.activePath, archivePath: paths.archivePath, domainCode: domainCode)
    let folderName = "\(domainCode)-\(formatted) \(title)"
    let projectPath = (paths.activePath as NSString).appendingPathComponent(folderName)
    let fm = FileManager.default
    try fm.createDirectory(atPath: projectPath, withIntermediateDirectories: true)
    for sub in config.subfolders {
        try fm.createDirectory(atPath: (projectPath as NSString).appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    let notesContent = try getNotesTemplateContent(templatePath: config.notesTemplatePath, title: title)
    let notesPath = getNotesPath(projectPath: projectPath)
    try notesContent.write(toFile: notesPath, atomically: true, encoding: .utf8)
    return projectPath
}
