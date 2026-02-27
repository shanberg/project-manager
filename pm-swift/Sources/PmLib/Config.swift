import Foundation

public struct PmConfig: Codable, Equatable {
    public var paraPath: String?
    public var activePath: String
    public var archivePath: String
    public var domains: [String: String]
    public var subfolders: [String]
    /// Optional path to a custom notes template file (supports ~). If set, the file must exist.
    public var notesTemplatePath: String?

    public init(paraPath: String? = nil, activePath: String, archivePath: String, domains: [String: String], subfolders: [String], notesTemplatePath: String? = nil) {
        self.paraPath = paraPath
        self.activePath = activePath
        self.archivePath = archivePath
        self.domains = domains
        self.subfolders = subfolders
        self.notesTemplatePath = notesTemplatePath
    }
}

public let defaultDomains: [String: String] = [
    "W": "Work",
    "P": "Personal",
    "L": "Learning",
    "O": "Other",
]

public let defaultSubfolders = [
    "deliverables",
    "docs",
    "resources",
    "previews",
    "working files",
]

public func getConfigDir() -> String {
    if let pmConfig = ProcessInfo.processInfo.environment["PM_CONFIG_HOME"], !pmConfig.isEmpty {
        return (pmConfig as NSString).expandingTildeInPath
    }
    if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
        return (xdg as NSString).appendingPathComponent("pm")
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return (home as NSString).appendingPathComponent(".config/pm")
}

public func getConfigPath() -> String {
    (getConfigDir() as NSString).appendingPathComponent("config.json")
}

/// Load config from disk. Returns nil only if the config file does not exist; throws on read or decode errors.
/// Single read (no separate fileExists) and memory-mapped I/O when safe for small config files.
public func loadConfig() throws -> PmConfig? {
    let path = getConfigPath()
    let url = URL(fileURLWithPath: path)
    let data: Data
    do {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
    } catch {
        let ns = error as NSError
        // 260 = CocoaError.fileReadNoSuchFile
        if ns.domain == NSCocoaErrorDomain && ns.code == 260 { return nil }
        throw error
    }
    return try JSONDecoder().decode(PmConfig.self, from: data)
}

public func saveConfig(_ config: PmConfig) throws {
    let dir = getConfigDir()
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = getConfigPath()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(config)
    try data.write(to: URL(fileURLWithPath: path))
}

public func createDefaultConfig(activePath: String, archivePath: String) -> PmConfig {
    PmConfig(
        activePath: activePath,
        archivePath: archivePath,
        domains: defaultDomains,
        subfolders: defaultSubfolders
    )
}

public struct ResolvedPaths {
    public let activePath: String
    public let archivePath: String
}

/// Resolve active/archive paths from config (and optional env). Pass nil for env to use process environment.
internal func resolvePaths(config: PmConfig, environment: [String: String]?) throws -> ResolvedPaths {
    let env = environment ?? ProcessInfo.processInfo.environment
    if let a = env["PM_ACTIVE_PATH"], let b = env["PM_ARCHIVE_PATH"], !a.isEmpty, !b.isEmpty {
        return ResolvedPaths(activePath: (a as NSString).expandingTildeInPath, archivePath: (b as NSString).expandingTildeInPath)
    }
    if !config.activePath.isEmpty, !config.archivePath.isEmpty {
        return ResolvedPaths(
            activePath: (config.activePath as NSString).expandingTildeInPath,
            archivePath: (config.archivePath as NSString).expandingTildeInPath
        )
    }
    if let para = config.paraPath, !para.isEmpty {
        let base = (para as NSString).expandingTildeInPath
        return ResolvedPaths(
            activePath: (base as NSString).appendingPathComponent("active"),
            archivePath: (base as NSString).appendingPathComponent("archive")
        )
    }
    throw PmError.configMissingPaths
}

public func resolvePaths(config: PmConfig) throws -> ResolvedPaths {
    try resolvePaths(config: config, environment: nil)
}

/// Throws if active or archive directory does not exist.
public func validatePathsExist(paths: ResolvedPaths) throws {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    if !fm.fileExists(atPath: paths.activePath, isDirectory: &isDir) || !isDir.boolValue {
        throw PmError.activePathNotFound(paths.activePath)
    }
    if !fm.fileExists(atPath: paths.archivePath, isDirectory: &isDir) || !isDir.boolValue {
        throw PmError.archivePathNotFound(paths.archivePath)
    }
}

/// Load config and resolve paths. When `skipPathValidation` is false, validates that active and archive directories exist.
/// Use `skipPathValidation: true` only for read-only list; other commands should validate.
public func loadConfigAndPaths(skipPathValidation: Bool = false) throws -> (PmConfig, ResolvedPaths) {
    guard let config = try loadConfig() else { throw PmError.configNotFound }
    let paths = try resolvePaths(config: config)
    if !skipPathValidation {
        try validatePathsExist(paths: paths)
    }
    return (config, paths)
}

public enum PmConfigKey: String, CaseIterable {
    case activePath, archivePath, paraPath, domains, subfolders, notesTemplatePath
}

public func getConfigValue(config: PmConfig, key: String) -> Any? {
    switch key {
    case "activePath": return config.activePath
    case "archivePath": return config.archivePath
    case "paraPath": return config.paraPath as Any?
    case "domains": return config.domains
    case "subfolders": return config.subfolders
    case "notesTemplatePath": return config.notesTemplatePath as Any?
    default: return nil
    }
}

public func setConfigValue(config: inout PmConfig, key: String, value: Any) throws {
    switch key {
    case "activePath":
        guard let v = value as? String else { throw PmError.invalidConfigValue(key: key, expectedType: "String") }
        config.activePath = v
    case "archivePath":
        guard let v = value as? String else { throw PmError.invalidConfigValue(key: key, expectedType: "String") }
        config.archivePath = v
    case "paraPath":
        config.paraPath = value as? String
    case "domains":
        guard let v = value as? [String: String] else { throw PmError.invalidConfigValue(key: key, expectedType: "object (key-value pairs)") }
        config.domains = v
    case "subfolders":
        guard let v = value as? [String] else { throw PmError.invalidConfigValue(key: key, expectedType: "array of strings") }
        config.subfolders = v
    case "notesTemplatePath":
        config.notesTemplatePath = (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    default: throw PmError.unknownConfigKey(key)
    }
}

public enum PmError: Error, CustomStringConvertible {
    case configNotFound
    case configMissingPaths
    case activePathNotFound(String)
    case archivePathNotFound(String)
    case unknownConfigKey(String)
    case invalidConfigValue(key: String, expectedType: String)
    case projectNotFound(String)
    case ambiguousProject(String)
    case notesNotFound(String)
    case notesAlreadyExists(String)
    case notesTemplateNotFound(String)
    case notesRegexError(pattern: String)

    public var description: String {
        switch self {
        case .configNotFound: return "Config not found. Run 'pm config init' first."
        case .configMissingPaths: return "Config must have activePath and archivePath (or paraPath, or PM_ACTIVE_PATH/PM_ARCHIVE_PATH env)"
        case .activePathNotFound(let path): return "Active path does not exist or is not a directory: \(path)"
        case .archivePathNotFound(let path): return "Archive path does not exist or is not a directory: \(path)"
        case .unknownConfigKey(let k): return "Unknown key: \(k)"
        case .invalidConfigValue(let k, let expected): return "Invalid value for \(k): expected \(expected)"
        case .projectNotFound(let q): return "No project found matching: \(q)"
        case .ambiguousProject(let q): return "Ambiguous match. Multiple projects start with: \(q)"
        case .notesNotFound(let path): return "Notes file not found. Expected: \(path)"
        case .notesAlreadyExists(let path): return "Notes file already exists: \(path)"
        case .notesTemplateNotFound(let path): return "Notes template file not found: \(path)"
        case .notesRegexError(let pattern): return "Invalid notes regex pattern: \(pattern)"
        }
    }
}
