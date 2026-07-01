import Foundation
import PmLib

/// Minimal append-only diagnostic log written to `~/.config/pm/pm-mac.log` (an unprotected location,
/// unlike the projects folder). Used to trace startup and reload failures during development.
enum Log {
    private static let queue = DispatchQueue(label: "com.stuarthanberg.pm.log")
    private static var url: URL { PMFiles.configDir.appendingPathComponent("pm-mac.log") }

    static func write(_ message: String) {
        queue.async {
            let line = "\(Self.timestamp()) \(message)\n"
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
