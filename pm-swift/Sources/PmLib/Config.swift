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

/// True if the error indicates "file or directory does not exist" (CocoaError.fileReadNoSuchFile).
/// Use this instead of checking NSError.code == 260 so the intent is documented and consistent.
internal func isFileNotFoundError(_ error: Error) -> Bool {
    let ns = error as NSError
    return ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.Code.fileReadNoSuchFile.rawValue
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
        if isFileNotFoundError(error) { return nil }
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

/// Typed result of reading a config key. Use this instead of Any? so "unknown key" and "optional key with nil" are explicit.
public enum PmConfigValue {
    case unknownKey
    case string(String?)
    case stringArray([String])
    case stringDictionary([String: String])
}

/// Supported keys and value types (for `getConfigValue` / `setConfigValue`):
/// - activePath, archivePath, paraPath, notesTemplatePath: String? (paths support ~; paraPath/notesTemplatePath may be nil)
/// - domains: [String: String]
/// - subfolders: [String]
/// Returns a typed value; use .unknownKey when the key is not in the config.
public func getConfigValue(config: PmConfig, key: PmConfigKey) -> PmConfigValue {
    switch key {
    case .activePath: return .string(config.activePath)
    case .archivePath: return .string(config.archivePath)
    case .paraPath: return .string(config.paraPath)
    case .notesTemplatePath: return .string(config.notesTemplatePath)
    case .domains: return .stringDictionary(config.domains)
    case .subfolders: return .stringArray(config.subfolders)
    }
}

/// String-based overload for CLI. Returns .unknownKey when key is not a valid PmConfigKey.
public func getConfigValue(config: PmConfig, key: String) -> PmConfigValue {
    guard let k = PmConfigKey(rawValue: key) else { return .unknownKey }
    return getConfigValue(config: config, key: k)
}

/// Set a config key with a typed value. Throws on type mismatch (e.g. .stringArray for .domains).
public func setConfigValue(config: inout PmConfig, key: PmConfigKey, value: PmConfigValue) throws {
    switch (key, value) {
    case (.activePath, .string(let v)):
        guard let v = v else { throw PmError.invalidConfigValue(key: key.rawValue, expectedType: "String") }
        config.activePath = v
    case (.archivePath, .string(let v)):
        guard let v = v else { throw PmError.invalidConfigValue(key: key.rawValue, expectedType: "String") }
        config.archivePath = v
    case (.paraPath, .string(let v)):
        config.paraPath = v.flatMap { $0.isEmpty ? nil : $0 }
    case (.notesTemplatePath, .string(let v)):
        config.notesTemplatePath = v.flatMap { $0.isEmpty ? nil : $0 }
    case (.domains, .stringDictionary(let v)):
        config.domains = v
    case (.subfolders, .stringArray(let v)):
        config.subfolders = v
    default:
        throw PmError.invalidConfigValue(key: key.rawValue, expectedType: typeName(for: key))
    }
}

private func typeName(for key: PmConfigKey) -> String {
    switch key {
    case .activePath, .archivePath, .paraPath, .notesTemplatePath: return "String"
    case .domains: return "object (key-value pairs)"
    case .subfolders: return "array of strings"
    }
}

/// Extension so callers can read optional string from PmConfigValue for paraPath/notesTemplatePath.
public extension PmConfigValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// Set a config key from CLI input (string key and untyped value). Throws on unknown key or type mismatch.
public func setConfigValue(config: inout PmConfig, key: String, value: Any) throws {
    guard let k = PmConfigKey(rawValue: key) else { throw PmError.unknownConfigKey(key) }
    let typed: PmConfigValue
    switch k {
    case .activePath, .archivePath:
        guard let v = value as? String else { throw PmError.invalidConfigValue(key: key, expectedType: "String") }
        typed = .string(v)
    case .paraPath:
        typed = .string(value as? String)
    case .notesTemplatePath:
        typed = .string(value as? String)
    case .domains:
        guard let v = value as? [String: String] else { throw PmError.invalidConfigValue(key: key, expectedType: "object (key-value pairs)") }
        typed = .stringDictionary(v)
    case .subfolders:
        guard let v = value as? [String] else { throw PmError.invalidConfigValue(key: key, expectedType: "array of strings") }
        typed = .stringArray(v)
    }
    try setConfigValue(config: &config, key: k, value: typed)
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
    /// Project name or prefix argument was empty or only whitespace.
    case emptyProjectQuery
    case notesNotFound(String)
    case notesAlreadyExists(String)
    case notesTemplateNotFound(String)
    case notesRegexError(pattern: String)
    /// Directory exists but listing contents failed (e.g. permission denied).
    case cannotListDirectory(path: String, message: String)
    /// Project folder pattern could not be built from domain codes (e.g. invalid regex).
    case invalidProjectPattern(pattern: String)
    /// Session date argument could not be parsed (e.g. --date value).
    case invalidSessionDate(value: String)
    /// Project title must not contain path separators (e.g. / or \).
    case invalidProjectTitle(title: String)

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
        case .emptyProjectQuery: return "Project name or prefix cannot be empty."
        case .notesNotFound(let path): return "Notes file not found. Expected: \(path)"
        case .notesAlreadyExists(let path): return "Notes file already exists: \(path)"
        case .notesTemplateNotFound(let path): return "Notes template file not found: \(path)"
        case .notesRegexError(let pattern): return "Invalid notes regex pattern: \(pattern)"
        case .cannotListDirectory(let path, let message): return "Cannot list directory: \(path). \(message)"
        case .invalidProjectPattern(let pattern): return "Invalid project pattern (check domains in config): \(pattern)"
        case .invalidSessionDate(let value): return "Invalid date for session: \(value). Use YYYY-MM-DD."
        case .invalidProjectTitle(let title): return "Project title cannot contain path separators (/ or \\): \(title)"
        }
    }
}
