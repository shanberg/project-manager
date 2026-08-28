import Foundation
import PmLib

/// Minimal append-only diagnostic log written to `~/.config/pm/pm-mac.log` (an unprotected location,
/// unlike the projects folder). Used to trace startup and reload failures during development.
///
/// Off in a release build unless it's asked for. The log is genuinely useful when something goes
/// wrong in the field — which is why it has a switch rather than being deleted — but some of what
/// writes to it is per-frame rather than per-event: the status item's menu traces every row the
/// pointer crosses, so an unswitched log means a file write per row hover, for the life of the app,
/// on a menu that opens dozens of times a day.
enum Log {
    private static let queue = DispatchQueue(label: "com.stuarthanberg.pm.log")
    private static var url: URL { PMFiles.configDir.appendingPathComponent("pm-mac.log") }

    /// Whether anything is written at all. Three ways in, resolved once:
    ///
    ///   * a debug build, where tracing is the point;
    ///   * `PM_LOG=1` in the environment, for a run started from a terminal to chase something down;
    ///   * `defaults write com.stuarthanberg.pm PMLogEnabled -bool YES`, for a copy already installed
    ///     in `/Applications` that has to be asked to talk on the next launch.
    ///
    /// Read once rather than per call: this is a question about how the app was started, and a log
    /// that could turn itself on halfway through a session would be a log with a gap in it.
    static let isEnabled: Bool = {
        #if DEBUG
        return true
        #else
        if let flag = ProcessInfo.processInfo.environment["PM_LOG"] {
            return !["0", "false", "no", ""].contains(flag.lowercased())
        }
        return UserDefaults.standard.bool(forKey: "PMLogEnabled")
        #endif
    }()

    /// `@autoclosure` so a disabled log costs nothing at the call site. Every one of these is written
    /// as an interpolation — `"MENU highlight top -> \(item?.title ?? "nil")"` — and building that
    /// string is most of the work; passing it unevaluated means a switched-off log doesn't even
    /// format the line it isn't going to write.
    static func write(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        queue.async {
            let line = "\(Self.timestamp()) \(text)\n"
            guard let data = line.data(using: .utf8) else { return }
            try? FileManager.default.createDirectory(at: PMFiles.configDir, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
