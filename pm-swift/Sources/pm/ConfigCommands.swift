import Foundation
import PmLib

func runConfigInit() {
    do {
        let existing = try loadConfig()
        if existing != nil {
            print("Config already exists at: \(getConfigPath())")
            print("Re-initialize? (y/N): ", terminator: "")
            guard let line = readLine(), line.lowercased() == "y" else { return }
        }
        print("Enter the path for active projects:")
        print("Active path: ", terminator: "")
        guard let activePath = readLine()?.trimmingCharacters(in: .whitespaces), !activePath.isEmpty else {
            stderr("No active path provided.")
            exit(1)
        }
        print("Enter the path for archived projects:")
        print("Archive path: ", terminator: "")
        guard let archivePath = readLine()?.trimmingCharacters(in: .whitespaces), !archivePath.isEmpty else {
            stderr("No archive path provided.")
            exit(1)
        }
        let activeExpanded = (activePath as NSString).expandingTildeInPath
        let archiveExpanded = (archivePath as NSString).expandingTildeInPath
        if activeExpanded == archiveExpanded {
            stderr("Active and archive paths must be different.")
            exit(1)
        }
        let config = createDefaultConfig(activePath: activePath, archivePath: archivePath)
        try FileManager.default.createDirectory(atPath: activeExpanded, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: archiveExpanded, withIntermediateDirectories: true)
        try saveConfig(config)
        print("Config saved to: \(getConfigPath())")
        print("Active: \(activeExpanded)")
        print("Archive: \(archiveExpanded)")
    } catch { fail(error) }
}

/// The value `pm config get` shows for a key.
///
/// `getConfigValue` reports the configuration as stored, which is the right answer for a key that was
/// written down and the wrong one for `areasPath`: it is unset in every config predating Areas, and
/// printing "null" would tell a reader nothing about where their areas actually live. Resolved here,
/// once, so the single-key form and the whole-config dump can't disagree about it.
private func displayValue(for key: PmConfigKey, config: PmConfig) -> PmConfigValue {
    if key == .areasPath, let resolved = try? resolvePaths(config: config).areasPath {
        return .string(resolved)
    }
    return getConfigValue(config: config, key: key)
}

private func render(_ value: PmConfigValue, key: String) throws -> String {
    switch value {
    case .unknownKey: fail(PmError.unknownConfigKey(key))
    case .string(let s): return s ?? "null"
    case .bool(let b): return "\(b)"
    case .stringArray(let a): return try prettyJSON(a as NSArray, key: key)
    case .stringDictionary(let d): return try prettyJSON(d as NSDictionary, key: key)
    }
}

private func prettyJSON(_ object: Any, key: String) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: .prettyPrinted)
    guard let str = String(data: data, encoding: .utf8) else {
        stderr("Failed to encode config value '\(key)' as UTF-8.")
        exit(1)
    }
    return str
}

func runConfigGet(key: String?) {
    do {
        guard let config = try loadConfig() else { fail(PmError.configNotFound) }
        if let k = key {
            // The key table lives in PmLib and is the same one `config set` validates against. This
            // used to be a second copy of it here, which is how `areasPath` came to be readable in the
            // whole-config dump and "unknown" when asked for by name.
            guard let typed = PmConfigKey(rawValue: k) else { fail(PmError.unknownConfigKey(k)) }
            print(try render(displayValue(for: typed, config: config), key: k))
        } else {
            var obj: [String: Any] = [
                "activePath": config.activePath,
                "archivePath": config.archivePath,
                "domains": config.domains,
                "subfolders": config.subfolders,
            ]
            obj["paraPath"] = config.paraPath ?? NSNull()
            // Resolved rather than raw. `areasPath` is unset in every config written before Areas
            // existed, and a reader handed null would have to re-derive the fallback itself — which is
            // the same rule stated twice, in another language, in the surface most likely to drift.
            obj["areasPath"] = displayValue(for: .areasPath, config: config).stringValue ?? NSNull()
            obj["areaSubfolders"] = config.areaSubfolders ?? defaultAreaSubfolders
            obj["notesTemplatePath"] = config.notesTemplatePath ?? NSNull()
            obj["areaNotesTemplatePath"] = config.areaNotesTemplatePath ?? NSNull()
            obj["useObsidianCLI"] = config.useObsidianCLI ?? false
            obj["obsidianVault"] = config.obsidianVault ?? NSNull()
            obj["obsidianVaultPath"] = config.obsidianVaultPath ?? NSNull()
            let data = try JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted)
            guard let str = String(data: data, encoding: .utf8) else {
                stderr("Failed to encode config JSON as UTF-8.")
                exit(1)
            }
            print(str)
        }
    } catch { fail(error) }
}

func runConfigSet(key: String, valueStr: String) {
    do {
        guard var config = try loadConfig() else { fail(PmError.configNotFound) }
        guard let typed = PmConfigKey(rawValue: key) else { fail(PmError.unknownConfigKey(key)) }
        // Which keys take JSON and which take a plain string is a fact about the key, and it lives with
        // the key. This used to be a list here, and a key added to the table without also being added
        // to the list was readable in the dump and unsettable.
        let value: Any
        switch configValueKind(for: typed) {
        case .string, .bool:
            value = valueStr
        case .stringArray, .stringDictionary:
            guard let data = valueStr.data(using: .utf8) else {
                stderr("Invalid UTF-8 in value.")
                exit(1)
            }
            do {
                value = try JSONSerialization.jsonObject(with: data)
            } catch {
                fail(PmError.invalidConfigValue(key: key, expectedType: "valid JSON"))
            }
        }
        try setConfigValue(config: &config, key: key, value: value)
        try saveConfig(config)
        print("Updated \(key)")
    } catch { fail(error) }
}

func runConfig(args: [String]) {
    guard let sub = args.first else {
        stderr("Usage: pm config <init|get|set> ...")
        exit(1)
    }
    switch sub {
    case "init":
        runConfigInit()
    case "get":
        runConfigGet(key: args.count > 1 ? args[1] : nil)
    case "set":
        guard args.count >= 3 else {
            stderr("Usage: pm config set <key> <value>")
            exit(1)
        }
        runConfigSet(key: args[1], valueStr: args.dropFirst(2).joined(separator: " "))
    default:
        stderr("Usage: pm config <init|get|set> ...")
        exit(1)
    }
}
