import Foundation

public struct PmConfig: Codable, Equatable {
    public var paraPath: String?
    public var activePath: String
    public var archivePath: String
    /// Where Areas live. Nil means "work it out" — see `resolvePaths`. Areas arrived after the other
    /// two roots, so every existing config has this unset and has to keep working.
    public var areasPath: String?
    public var domains: [String: String]
    public var subfolders: [String]
    /// The scaffold a new Area is created with. Nil means `defaultAreaSubfolders`.
    public var areaSubfolders: [String]?
    /// Optional path to a custom notes template file (supports ~). If set, the file must exist.
    public var notesTemplatePath: String?
    /// The same, for Areas. Separate from `notesTemplatePath` because a project template has a Problem
    /// and an Approach in it, and pointing Areas at it would hand every Area the two sections the kind
    /// exists to leave out.
    public var areaNotesTemplatePath: String?
    /// When true and obsidianVault/obsidianVaultPath are set, notes read/write may use the Obsidian CLI. Nil (missing in JSON) is treated as false.
    public var useObsidianCLI: Bool?
    /// Vault name for the Obsidian CLI (e.g. "MyVault"). Required when useObsidianCLI is true.
    public var obsidianVault: String?
    /// Absolute path to vault root (supports ~). Used to compute relative path for CLI. Required when useObsidianCLI is true.
    public var obsidianVaultPath: String?

    public init(paraPath: String? = nil, activePath: String, archivePath: String, areasPath: String? = nil, domains: [String: String], subfolders: [String], areaSubfolders: [String]? = nil, notesTemplatePath: String? = nil, areaNotesTemplatePath: String? = nil, useObsidianCLI: Bool? = nil, obsidianVault: String? = nil, obsidianVaultPath: String? = nil) {
        self.paraPath = paraPath
        self.activePath = activePath
        self.archivePath = archivePath
        self.areasPath = areasPath
        self.domains = domains
        self.subfolders = subfolders
        self.areaSubfolders = areaSubfolders
        self.notesTemplatePath = notesTemplatePath
        self.areaNotesTemplatePath = areaNotesTemplatePath
        self.useObsidianCLI = useObsidianCLI
        self.obsidianVault = obsidianVault
        self.obsidianVaultPath = obsidianVaultPath
    }
}

public let defaultDomains: [String: String] = [
    "W": "Work",
    "P": "Personal",
    "L": "Learning",
    "O": "Other",
]

/// An Area has notes and reference material. It doesn't ship, so it gets no `deliverables/`,
/// `previews/` or `working files/` — those are project vocabulary.
public let defaultAreaSubfolders = [
    "docs",
    "resources",
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
    /// Always resolved, never optional — an unconfigured `areas/` that doesn't exist on disk is a
    /// vault with no Areas in it, which every scan already handles as "nothing here". Making it
    /// optional would put a `guard` in front of each of those for no additional truth.
    public let areasPath: String

    /// `areasPath` defaults to the same guess `resolvePaths` makes when nothing configures one, so a
    /// caller assembling paths by hand — the tests, and the app repointing folders from Settings —
    /// gets the same answer as a caller that went through config.
    public init(activePath: String, archivePath: String, areasPath: String? = nil) {
        self.activePath = activePath
        self.archivePath = archivePath
        self.areasPath = areasPath ?? defaultAreasPath(besideActive: activePath)
    }
}

/// The areas folder inside `parent`, spelled the way the filesystem spells it.
///
/// A derived path picks the name, and a PARA vault laid out as `Projects` / `Archive` / `Areas` has
/// picked a different one. On a case-insensitive volume the difference is invisible to `fileExists` —
/// the folder opens, the scan works — and highly visible everywhere a path is *shown*: every message,
/// every JSON payload, every log line says `areas` about a folder called `Areas`. On a case-sensitive
/// volume it stops being cosmetic and PM makes a second directory beside the first.
///
/// `canonicalPath` is the filesystem's own answer to "what is this really called". Only the last
/// component of it is taken: the canonical form also resolves symlinks, and adopting the whole thing
/// would quietly re-root `areasPath` somewhere its siblings aren't (`/tmp` becoming `/private/tmp`
/// under `activePath` that still says `/tmp`).
///
/// Nil when nothing is there, which is the ordinary case for a vault that has never made one — and
/// then `areas` is as good a spelling as any, because PM is about to choose it.
func areasFolder(in parent: String) -> String {
    let candidate = (parent as NSString).appendingPathComponent("areas")
    guard let values = try? URL(fileURLWithPath: candidate).resourceValues(forKeys: [.canonicalPathKey]),
          let canonical = values.canonicalPath else { return candidate }
    return (parent as NSString).appendingPathComponent((canonical as NSString).lastPathComponent)
}

/// Where Areas go when nothing says otherwise: beside the active folder.
///
/// A guess, and a cheap one to be wrong about. Scanning a directory that isn't there yields no Areas,
/// which is the correct answer for a vault that has none; the only way the guess becomes visible is
/// when the first Area is created and the folder appears next to `active/`. Setting `areasPath` or
/// `paraPath` overrides it.
func defaultAreasPath(besideActive activePath: String) -> String {
    areasFolder(in: (activePath as NSString).deletingLastPathComponent)
}

/// Resolve active/archive paths from config (and optional env). Pass nil for env to use process environment.
internal func resolvePaths(config: PmConfig, environment: [String: String]?) throws -> ResolvedPaths {
    let env = environment ?? ProcessInfo.processInfo.environment

    /// Areas are resolved the same way whichever branch below settles active and archive: an explicit
    /// value wins, then `paraPath`, then beside the active folder.
    func areas(activePath: String) -> String {
        if let a = env["PM_AREAS_PATH"], !a.isEmpty { return (a as NSString).expandingTildeInPath }
        if let a = config.areasPath, !a.isEmpty { return (a as NSString).expandingTildeInPath }
        if let para = config.paraPath, !para.isEmpty {
            return areasFolder(in: (para as NSString).expandingTildeInPath)
        }
        return defaultAreasPath(besideActive: activePath)
    }

    if let a = env["PM_ACTIVE_PATH"], let b = env["PM_ARCHIVE_PATH"], !a.isEmpty, !b.isEmpty {
        let active = (a as NSString).expandingTildeInPath
        return ResolvedPaths(activePath: active,
                             archivePath: (b as NSString).expandingTildeInPath,
                             areasPath: areas(activePath: active))
    }
    if !config.activePath.isEmpty, !config.archivePath.isEmpty {
        let active = (config.activePath as NSString).expandingTildeInPath
        return ResolvedPaths(
            activePath: active,
            archivePath: (config.archivePath as NSString).expandingTildeInPath,
            areasPath: areas(activePath: active)
        )
    }
    if let para = config.paraPath, !para.isEmpty {
        let base = (para as NSString).expandingTildeInPath
        let active = (base as NSString).appendingPathComponent("active")
        return ResolvedPaths(
            activePath: active,
            archivePath: (base as NSString).appendingPathComponent("archive"),
            areasPath: areas(activePath: active)
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
    case activePath, archivePath, areasPath, paraPath, domains, subfolders, areaSubfolders, notesTemplatePath, areaNotesTemplatePath
    case useObsidianCLI, obsidianVault, obsidianVaultPath
}

/// Typed result of reading a config key. Use this instead of Any? so "unknown key" and "optional key with nil" are explicit.
public enum PmConfigValue {
    case unknownKey
    case string(String?)
    case stringArray([String])
    case stringDictionary([String: String])
    case bool(Bool)
}

/// Supported keys and value types (for `getConfigValue` / `setConfigValue`):
/// - activePath, archivePath, paraPath, notesTemplatePath, obsidianVault, obsidianVaultPath: String? (paths support ~; optional keys may be nil)
/// - useObsidianCLI: Bool
/// - domains: [String: String]
/// - subfolders: [String]
/// Returns a typed value; use .unknownKey when the key is not in the config.
public func getConfigValue(config: PmConfig, key: PmConfigKey) -> PmConfigValue {
    switch key {
    case .activePath: return .string(config.activePath)
    case .archivePath: return .string(config.archivePath)
    case .areasPath: return .string(config.areasPath)
    case .paraPath: return .string(config.paraPath)
    case .notesTemplatePath: return .string(config.notesTemplatePath)
    case .areaNotesTemplatePath: return .string(config.areaNotesTemplatePath)
    case .useObsidianCLI: return .bool(config.useObsidianCLI ?? false)
    case .obsidianVault: return .string(config.obsidianVault)
    case .obsidianVaultPath: return .string(config.obsidianVaultPath)
    case .domains: return .stringDictionary(config.domains)
    case .subfolders: return .stringArray(config.subfolders)
    case .areaSubfolders: return .stringArray(config.areaSubfolders ?? defaultAreaSubfolders)
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
    case (.areasPath, .string(let v)):
        config.areasPath = v.flatMap { $0.isEmpty ? nil : $0 }
    case (.paraPath, .string(let v)):
        config.paraPath = v.flatMap { $0.isEmpty ? nil : $0 }
    case (.notesTemplatePath, .string(let v)):
        config.notesTemplatePath = v.flatMap { $0.isEmpty ? nil : $0 }
    case (.areaNotesTemplatePath, .string(let v)):
        config.areaNotesTemplatePath = v.flatMap { $0.isEmpty ? nil : $0 }
    case (.useObsidianCLI, .bool(let v)):
        config.useObsidianCLI = v
    case (.obsidianVault, .string(let v)):
        config.obsidianVault = v.flatMap { $0.isEmpty ? nil : $0 }
    case (.obsidianVaultPath, .string(let v)):
        config.obsidianVaultPath = v.flatMap { $0.isEmpty ? nil : $0 }
    case (.domains, .stringDictionary(let v)):
        config.domains = v
    case (.subfolders, .stringArray(let v)):
        config.subfolders = v
    case (.areaSubfolders, .stringArray(let v)):
        config.areaSubfolders = v.isEmpty ? nil : v
    default:
        throw PmError.invalidConfigValue(key: key.rawValue, expectedType: typeName(for: key))
    }
}

/// What shape a config key's value has.
///
/// Published because every surface that reads or writes config needs it and each one had grown its own
/// copy: `pm config set` decided which keys take JSON by listing them, and `pm config get` listed them
/// again to decide how to print. Two hand-kept lists beside the real one is how `areasPath` came to be
/// in the whole-config dump, "unknown" when asked for by name, and unsettable.
public enum PmConfigValueKind {
    case string, bool, stringArray, stringDictionary
}

public func configValueKind(for key: PmConfigKey) -> PmConfigValueKind {
    switch key {
    case .activePath, .archivePath, .areasPath, .paraPath,
         .notesTemplatePath, .areaNotesTemplatePath, .obsidianVault, .obsidianVaultPath: return .string
    case .useObsidianCLI: return .bool
    case .domains: return .stringDictionary
    case .subfolders, .areaSubfolders: return .stringArray
    }
}

private func typeName(for key: PmConfigKey) -> String {
    switch configValueKind(for: key) {
    case .string: return "String"
    case .bool: return "Boolean"
    case .stringDictionary: return "object (key-value pairs)"
    case .stringArray: return "array of strings"
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
    case .areasPath, .paraPath, .notesTemplatePath, .areaNotesTemplatePath, .obsidianVault, .obsidianVaultPath:
        typed = .string(value as? String)
    case .useObsidianCLI:
        if let v = value as? Bool {
            typed = .bool(v)
        } else if let s = value as? String {
            let lower = s.lowercased()
            if lower == "true" || lower == "1" { typed = .bool(true) }
            else if lower == "false" || lower == "0" { typed = .bool(false) }
            else { throw PmError.invalidConfigValue(key: key, expectedType: "Boolean") }
        } else {
            throw PmError.invalidConfigValue(key: key, expectedType: "Boolean")
        }
    case .domains:
        guard let v = value as? [String: String] else { throw PmError.invalidConfigValue(key: key, expectedType: "object (key-value pairs)") }
        typed = .stringDictionary(v)
    case .subfolders, .areaSubfolders:
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
    /// A domain code that isn't in the configured domains.
    case unknownDomain(String)
    /// A domain was given for something that isn't numbered, or withheld from something that is.
    case domainNotApplicable(kind: String)
    /// A write tried to introduce a header section the kind doesn't have.
    case sectionNotApplicable(kind: String, section: String)
    /// A folder can't be taken on as an area, and why.
    case cannotAdopt(name: String, reason: String)
    /// An Area of that name already exists. Projects can't collide — their numbers are unique — but
    /// Areas are named by hand, and creating a second "Hiring" would write over the first one's notes.
    case areaAlreadyExists(String)
    /// Obsidian CLI read failed (path, message from CLI or process).
    case obsidianCLIReadFailed(path: String, message: String)
    /// Obsidian CLI write/create failed (path, message from CLI or process).
    case obsidianCLIWriteFailed(path: String, message: String)
    /// Project folder name does not match `<domain>-<digits> <title>` for configured domains.
    case projectFolderMalformed(String)
    /// Rename target path already exists.
    case renameTargetExists(String)
    /// A project of that name is already in the folder it's being moved into.
    case moveTargetExists(String)
    /// `pm rename` new title was empty or only whitespace.
    case emptyRenameTitle
    /// Todo `due:` value was empty, multi-line, or contained reserved tokens (`due:`, `@`).
    case invalidTodoDue(String)
    /// Todo text was empty or only whitespace.
    case emptyTodoText
    /// Session note text was empty or only whitespace.
    case emptySessionNote
    /// A task reference no longer names the task it was read from — see docs/task-identity.md.
    case staleReference(detail: String)

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
        case .unknownDomain(let code): return "Unknown domain: \(code)"
        case .domainNotApplicable(let kind): return "A \(kind) doesn't take a domain code"
        case .sectionNotApplicable(let kind, let section): return "An \(kind) has no \(section) section"
        case .cannotAdopt(let name, let reason): return "Can't take on “\(name)”: \(reason)"
        case .areaAlreadyExists(let path): return "An area already exists at: \(path)"
        case .obsidianCLIReadFailed(let path, let message): return "Obsidian CLI read failed for \(path): \(message)"
        case .obsidianCLIWriteFailed(let path, let message): return "Obsidian CLI write failed for \(path): \(message)"
        case .projectFolderMalformed(let name): return "Project folder name is not valid for configured domains: \(name)"
        case .renameTargetExists(let path): return "A project folder already exists at: \(path)"
        case .moveTargetExists(let path): return "A project with that name is already there: \(path)"
        case .emptyRenameTitle: return "New project title cannot be empty."
        case .invalidTodoDue(let value): return "Invalid due value: \(value)"
        case .emptyTodoText: return "Task text is required."
        case .emptySessionNote: return "Session note text is required."
        case .staleReference(let detail): return "That task has changed since you read it: \(detail). Read the project again and retry."
        }
    }
}
