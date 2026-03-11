import Foundation

/// Writes a single NDJSON line to the path in DEBUG_LOG_PATH env (no-op if unset). Used for debug session instrumentation.
func debugLog(location: String, message: String, data: [String: Any], hypothesisId: String? = nil) {
    guard let path = ProcessInfo.processInfo.environment["DEBUG_LOG_PATH"], !path.isEmpty else { return }
    var payload: [String: Any] = [
        "sessionId": "801075",
        "location": location,
        "message": message,
        "data": data,
        "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
    ]
    if let hid = hypothesisId { payload["hypothesisId"] = hid }
    guard let json = try? JSONSerialization.data(withJSONObject: payload),
          let line = String(data: json, encoding: .utf8) else { return }
    let lineWithNewline = line + "\n"
    guard let writeData = lineWithNewline.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: path) {
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(writeData)
        try? handle.close()
    } else {
        FileManager.default.createFile(atPath: path, contents: writeData)
    }
}
