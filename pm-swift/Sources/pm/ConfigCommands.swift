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

func runConfigGet(key: String?) {
    do {
        guard let config = try loadConfig() else { fail(PmError.configNotFound) }
        if let k = key {
            switch k {
            case "activePath":
                print(config.activePath)
            case "archivePath":
                print(config.archivePath)
            case "paraPath":
                print(config.paraPath ?? "null")
            case "notesTemplatePath":
                print(config.notesTemplatePath ?? "null")
            case "useObsidianCLI":
                print(config.useObsidianCLI ?? false)
            case "obsidianVault":
                print(config.obsidianVault ?? "null")
            case "obsidianVaultPath":
                print(config.obsidianVaultPath ?? "null")
            case "domains":
                let data = try JSONSerialization.data(withJSONObject: config.domains as NSDictionary, options: .prettyPrinted)
                guard let str = String(data: data, encoding: .utf8) else {
                    stderr("Failed to encode config value '\(k)' as UTF-8.")
                    exit(1)
                }
                print(str)
            case "subfolders":
                let data = try JSONSerialization.data(withJSONObject: config.subfolders as NSArray, options: .prettyPrinted)
                guard let str = String(data: data, encoding: .utf8) else {
                    stderr("Failed to encode config value '\(k)' as UTF-8.")
                    exit(1)
                }
                print(str)
            default:
                fail(PmError.unknownConfigKey(k))
            }
        } else {
            var obj: [String: Any] = [
                "activePath": config.activePath,
                "archivePath": config.archivePath,
                "domains": config.domains,
                "subfolders": config.subfolders,
            ]
            obj["paraPath"] = config.paraPath ?? NSNull()
            obj["notesTemplatePath"] = config.notesTemplatePath ?? NSNull()
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
        if key == "activePath" || key == "archivePath" || key == "paraPath" {
            try setConfigValue(config: &config, key: key, value: valueStr)
        } else if key == "notesTemplatePath" || key == "obsidianVault" || key == "obsidianVaultPath" {
            try setConfigValue(config: &config, key: key, value: valueStr.isEmpty ? "" : valueStr)
        } else if key == "useObsidianCLI" {
            try setConfigValue(config: &config, key: key, value: valueStr)
        } else if key == "domains" || key == "subfolders" {
            guard let data = valueStr.data(using: .utf8) else {
                stderr("Invalid UTF-8 in value.")
                exit(1)
            }
            let value: Any
            do {
                value = try JSONSerialization.jsonObject(with: data)
            } catch {
                fail(PmError.invalidConfigValue(key: key, expectedType: "valid JSON"))
            }
            try setConfigValue(config: &config, key: key, value: value)
        } else {
            fail(PmError.unknownConfigKey(key))
        }
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
