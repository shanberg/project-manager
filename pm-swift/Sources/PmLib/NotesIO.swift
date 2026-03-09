import Foundation

/// Abstraction for reading and writing note file content. Allows swapping direct file I/O for Obsidian CLI when configured.
public protocol NotesIO {
    func readContent(path: String) throws -> String
    func writeContent(path: String, content: String) throws
}

/// Uses direct file I/O. No dependency on Obsidian.
public struct DirectNotesIO: NotesIO {
    public init() {}

    public func readContent(path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    public func writeContent(path: String, content: String) throws {
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - Obsidian CLI

/// Returns true if the `obsidian` CLI is available (e.g. Obsidian app installed and CLI enabled).
/// No compile-time dependency on Obsidian; only invokes the binary when called.
public func isObsidianCLIAvailable() -> Bool {
    let result = runProcess(executable: "/usr/bin/env", arguments: ["obsidian", "version"])
    return result.terminationStatus == 0
}

/// Choose NotesIO implementation from config. Returns DirectNotesIO when Obsidian is not configured or CLI is unavailable.
public func makeNotesIO(notesPath: String, config: PmConfig) -> NotesIO {
    guard config.useObsidianCLI == true,
          let vault = config.obsidianVault, !vault.isEmpty,
          let vaultPath = config.obsidianVaultPath, !vaultPath.isEmpty else {
        return DirectNotesIO()
    }
    guard isObsidianCLIAvailable() else {
        return DirectNotesIO()
    }
    return ObsidianNotesIO(vaultName: vault, vaultPath: vaultPath)
}

private func runProcess(executable: String, arguments: [String], stdinData: Data? = nil) -> (stdout: Data, stderr: Data, terminationStatus: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    if let data = stdinData {
        let inPipe = Pipe()
        process.standardInput = inPipe
        inPipe.fileHandleForWriting.write(data)
        try? inPipe.fileHandleForWriting.close()
    }
    do {
        try process.run()
        process.waitUntilExit()
        let stdout = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = errPipe.fileHandleForReading.readDataToEndOfFile()
        return (stdout, stderr, process.terminationStatus)
    } catch {
        return (Data(), (error.localizedDescription).data(using: .utf8) ?? Data(), -1)
    }
}

/// Uses the Obsidian CLI for read/write when the path is under the configured vault; otherwise falls back to direct file I/O.
public struct ObsidianNotesIO: NotesIO {
    private let vaultName: String
    private let vaultRootPath: String

    public init(vaultName: String, vaultPath: String) {
        self.vaultName = vaultName
        self.vaultRootPath = (vaultPath as NSString).expandingTildeInPath
    }

    public func readContent(path: String) throws -> String {
        if let relativePath = relativePathFromVault(path: path) {
            return try readViaCLI(relativePath: relativePath, absolutePath: path)
        }
        return try DirectNotesIO().readContent(path: path)
    }

    public func writeContent(path: String, content: String) throws {
        if let relativePath = relativePathFromVault(path: path) {
            return try writeViaCLI(relativePath: relativePath, absolutePath: path, content: content)
        }
        try DirectNotesIO().writeContent(path: path, content: content)
    }

    /// If path is under vaultRootPath, return path relative to vault root; otherwise nil.
    private func relativePathFromVault(path: String) -> String? {
        let root = vaultRootPath.hasSuffix("/") ? String(vaultRootPath.dropLast()) : vaultRootPath
        let pathNorm = (path as NSString).standardizingPath
        let rootNorm = (root as NSString).standardizingPath
        guard pathNorm == rootNorm || pathNorm.hasPrefix(rootNorm + "/") else { return nil }
        if pathNorm == rootNorm { return "" }
        return String(pathNorm.dropFirst(rootNorm.count + 1))
    }

    private func readViaCLI(relativePath: String, absolutePath: String) throws -> String {
        let result = runProcess(executable: "/usr/bin/env", arguments: ["obsidian", "read", "vault=\(vaultName)", "path=\(relativePath)"])
        guard result.terminationStatus == 0 else {
            let msg = String(data: result.stderr, encoding: .utf8) ?? String(data: result.stdout, encoding: .utf8) ?? "exit \(result.terminationStatus)"
            throw PmError.obsidianCLIReadFailed(path: absolutePath, message: msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let out = String(data: result.stdout, encoding: .utf8) else {
            throw PmError.obsidianCLIReadFailed(path: absolutePath, message: "CLI output was not valid UTF-8")
        }
        return out
    }

    private func writeViaCLI(relativePath: String, absolutePath: String, content: String) throws {
        // Obsidian CLI: create with path= and content=; overwrite so existing files are updated.
        // Docs say use \n for newlines in content= value, so escape backslashes then newlines.
        let contentEscaped = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
        let result = runProcess(executable: "/usr/bin/env", arguments: ["obsidian", "create", "vault=\(vaultName)", "path=\(relativePath)", "content=\(contentEscaped)", "overwrite"])
        guard result.terminationStatus == 0 else {
            let msg = String(data: result.stderr, encoding: .utf8) ?? String(data: result.stdout, encoding: .utf8) ?? "exit \(result.terminationStatus)"
            throw PmError.obsidianCLIWriteFailed(path: absolutePath, message: msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
