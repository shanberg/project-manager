// cookie-export: print a site's cookies from a browser profile as Playwright cookie JSON, on stdout.
//   cookie-export <domain> [source title, default "Google Chrome"]
// Uses Folio's CanvasCookieImport (compiled in), so it decrypts exactly as Copy Sign-In From does;
// the Keychain asks you once for "Chrome Safe Storage". Nothing is written to disk.
import Foundation

enum Log { static func write(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) } }

let args = CommandLine.arguments
guard args.count >= 2 else { Log.write("usage: cookie-export <domain> [source]"); exit(2) }
let wanted = args.count > 2 ? args[2] : "Google Chrome"
let sources = CanvasCookieImport.sources()
guard let source = sources.first(where: { $0.title == wanted }) else {
    Log.write("no source \(wanted); have: \(sources.map(\.title))"); exit(1)
}
let cookies = try CanvasCookieImport.read(source, domain: CanvasCookieImport.registrableDomain(of: args[1]))
let json: [[String: Any]] = cookies.map { c in
    var o: [String: Any] = ["name": c.name, "value": c.value, "domain": c.domain,
                            "path": c.path.isEmpty ? "/" : c.path, "secure": c.secure, "httpOnly": c.httpOnly,
                            "expires": c.expires.map { $0.timeIntervalSince1970 } ?? -1]
    switch c.sameSite { case .some(.sameSiteStrict): o["sameSite"] = "Strict"; case .some(.sameSiteLax): o["sameSite"] = "Lax"
                        default: o["sameSite"] = "None" }
    return o
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: json))
Log.write("\(json.count) cookies for \(args[1]) from \(source.title)")
