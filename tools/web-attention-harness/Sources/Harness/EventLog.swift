import AppKit

/// Every event, shown in the window's log pane — and, only when launched with `HARNESS_LOG_FILE=1`, as one
/// JSON object per line in ~/Library/Logs/WebAttentionHarness. Off by default: the lines carry message
/// previews from real accounts, and nothing should be written down until a session is meant to be read.
@MainActor
final class EventLog {
    static let shared = EventLog()

    static let writesFile = ProcessInfo.processInfo.environment["HARNESS_LOG_FILE"] == "1"

    let fileURL: URL?
    var onLine: ((String) -> Void)?
    private let handle: FileHandle?
    private let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private init() {
        guard Self.writesFile else {
            fileURL = nil
            handle = nil
            return
        }
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/WebAttentionHarness", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let file = folder.appendingPathComponent("events-\(stamp.string(from: Date())).jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        fileURL = file
        handle = try? FileHandle(forWritingTo: file)
    }

    func write(_ listener: String, _ kind: String, _ fields: [String: Any] = [:]) {
        let now = Date()
        var entry = fields.mapValues(Self.jsonSafe)
        entry["t"] = iso.string(from: now)
        entry["listener"] = listener
        entry["kind"] = kind
        if handle != nil, let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) {
            handle?.write(data)
            handle?.write(Data("\n".utf8))
        }
        let summary = fields.keys.sorted().map { key in
            let value = String(describing: fields[key].map(Self.jsonSafe) ?? "")
            return "\(key)=\(value.count > 140 ? value.prefix(140) + "…" : Substring(value))"
        }.joined(separator: "  ")
        onLine?("\(clock.string(from: now))  [\(listener)]  \(kind)  \(summary)")
    }

    private static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let value as String: return value
        case let value as NSNumber: return value
        case let value as [Any]: return value.map(jsonSafe)
        case let value as [String: Any]: return value.mapValues(jsonSafe)
        case is NSNull: return NSNull()
        default: return String(describing: value)
        }
    }
}
