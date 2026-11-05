import CommonCrypto
import Foundation
import Security
import SQLite3
import WebKit

/// Copy a site's sign-in from a browser you already use into a card's session.
///
/// - For sites whose sign-in won't complete in an embedded web view (Apple's, behind `idmsa.apple.com`;
///   anything passkey-only). Sign in there, copy the cookies here.
/// - Cookies only. Local storage stays behind: no browser offers it to another app in a readable form.
/// - Matched on the registrable domain, the same scope `CanvasWebSession.forget` signs out of.
/// - Reads a copy of the browser's file; the browser can stay open and nothing in it changes.
/// - Safari: needs Full Disk Access. Chromium browsers: one Keychain prompt per browser per launch.
/// - Session cookies (no expiry) come across as session cookies, so they last until Folio quits.
enum CanvasCookieImport {

    /// One cookie as a browser stored it.
    struct Cookie: Equatable {
        var domain: String
        var name: String
        var value: String
        var path: String
        var expires: Date?
        var secure: Bool
        var httpOnly: Bool
        var sameSite: HTTPCookieStringPolicy?

        var httpCookie: HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .domain: domain, .path: path.isEmpty ? "/" : path, .name: name, .value: value,
            ]
            if let expires { properties[.expires] = expires }
            if secure { properties[.secure] = "TRUE" }
            if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let sameSite { properties[.sameSitePolicy] = sameSite.rawValue }
            return HTTPCookie(properties: properties)
        }
    }

    enum Failure: Error, Equatable {
        /// macOS refused the file: Safari's cookies are behind Full Disk Access.
        case needsFullDiskAccess
        /// The Keychain prompt for the browser's key was refused or cancelled.
        case keychainRefused(String)
        case unreadable(String)
    }

    // MARK: Sources

    /// A browser profile that has a cookie file on this Mac.
    struct Source: Equatable {
        enum Kind: Equatable {
            case safari(URL)
            case chromium(URL, keychainService: String)
            case firefox(URL)
        }
        /// "Safari", "Chrome", "Chrome — Work".
        var title: String
        var kind: Kind
    }

    /// Chromium browsers by where they keep their profiles and the Keychain item that unlocks them.
    static let chromiumBrowsers: [(name: String, folder: String, service: String)] = [
        ("Chrome", "Google/Chrome", "Chrome Safe Storage"),
        ("Arc", "Arc/User Data", "Arc Safe Storage"),
        ("Brave", "BraveSoftware/Brave-Browser", "Brave Safe Storage"),
        ("Edge", "Microsoft Edge", "Microsoft Edge Safe Storage"),
        ("Vivaldi", "Vivaldi", "Vivaldi Safe Storage"),
        ("Chromium", "Chromium", "Chromium Safe Storage"),
    ]

    /// Every browser profile with cookies on this Mac, Safari first. File checks only: no file is read
    /// beyond each browser's small profile list.
    static func sources(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Source] {
        let fm = FileManager.default
        var found: [Source] = []

        let safari = home.appending(path: "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
        // Listed even when Full Disk Access hides it: choosing it is how you find out access is missing.
        if fm.fileExists(atPath: "/Applications/Safari.app") || fm.fileExists(atPath: safari.path) {
            found.append(Source(title: "Safari", kind: .safari(safari)))
        }

        let support = home.appending(path: "Library/Application Support")
        for browser in chromiumBrowsers {
            let root = support.appending(path: browser.folder)
            let profiles = chromiumProfiles(root: root)
            for profile in profiles {
                let title = profiles.count > 1 ? "\(browser.name) \u{2014} \(profile.name)" : browser.name
                found.append(Source(title: title,
                                    kind: .chromium(profile.cookies, keychainService: browser.service)))
            }
        }

        for profile in firefoxProfiles(root: support.appending(path: "Firefox")) {
            found.append(Source(title: profile.title, kind: .firefox(profile.cookies)))
        }
        return found
    }

    /// Profile folders holding a cookie file, named as the browser names them in `Local State`.
    static func chromiumProfiles(root: URL) -> [(name: String, cookies: URL)] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var names: [String: String] = [:]
        // read: a browser's local profile folder, for Copy Sign-In From.
        if let data = try? Data(contentsOf: root.appending(path: "Local State")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            for (dir, info) in cache {
                if let name = (info as? [String: Any])?["name"] as? String { names[dir] = name }
            }
        }
        return entries.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { dir in
            // Newer Chromium keeps the file under Network/; older at the profile's top.
            for sub in ["Network/Cookies", "Cookies"] {
                let file = root.appending(path: dir).appending(path: sub)
                if fm.fileExists(atPath: file.path) { return (names[dir] ?? dir, file) }
            }
            return nil
        }
    }

    /// Firefox profiles from `profiles.ini`, those with a cookie file.
    static func firefoxProfiles(root: URL) -> [(title: String, cookies: URL)] {
        // read: a browser's local profile folder, for Copy Sign-In From.
        guard let ini = try? String(contentsOf: root.appending(path: "profiles.ini"), encoding: .utf8) else {
            return []
        }
        var found: [(String, URL)] = []
        var name: String?, path: String?, relative = true
        func flush() {
            defer { name = nil; path = nil; relative = true }
            guard let path else { return }
            let folder = relative ? root.appending(path: path) : URL(fileURLWithPath: path)
            let cookies = folder.appending(path: "cookies.sqlite")
            guard FileManager.default.fileExists(atPath: cookies.path) else { return }
            found.append((name ?? folder.lastPathComponent, cookies))
        }
        for line in ini.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("[") { flush(); continue }
            if line.hasPrefix("Name=") { name = String(line.dropFirst(5)) }
            if line.hasPrefix("Path=") { path = String(line.dropFirst(5)) }
            if line.hasPrefix("IsRelative=") { relative = line.hasSuffix("1") }
        }
        flush()
        return found.map { profile in
            (found.count > 1 ? "Firefox \u{2014} \(profile.0)" : "Firefox", profile.1)
        }
    }

    // MARK: Reading

    /// Every cookie the source holds for `domain` and its subdomains. Blocking: run off the main thread.
    static func read(_ source: Source, domain: String) throws -> [Cookie] {
        switch source.kind {
        case .safari(let file):
            let data: Data
            do {
                // read: `read` runs off main (see its doc).
                data = try Data(contentsOf: file)
            } catch let error as CocoaError where error.code == .fileReadNoPermission {
                throw Failure.needsFullDiskAccess
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EPERM) {
                throw Failure.needsFullDiskAccess
            }
            return try parseBinaryCookies(data).filter { matches($0.domain, domain) }
        case .chromium(let file, let service):
            let key = try chromiumKey(service: service)
            return try readChromium(file, domain: domain, key: key)
        case .firefox(let file):
            return try readFirefox(file, domain: domain)
        }
    }

    /// Whether a cookie filed under `cookieDomain` belongs to `domain`.
    static func matches(_ cookieDomain: String, _ domain: String) -> Bool {
        var host = cookieDomain.lowercased()
        if host.hasPrefix(".") { host.removeFirst() }
        let domain = domain.lowercased()
        return host == domain || host.hasSuffix("." + domain)
    }

    /// The part of a host a sign-in is kept under: `music.apple.com` → `apple.com`,
    /// `app.example.co.uk` → `example.co.uk`. A short list of two-part suffixes, not the full public
    /// suffix list; a miss only widens the copy to one level up.
    static func registrableDomain(of host: String) -> String {
        var labels = host.lowercased().split(separator: ".").map(String.init)
        while labels.last?.isEmpty == true { labels.removeLast() }
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let secondLevel = ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or", "go"]
        let keep = labels.last!.count == 2 && secondLevel.contains(labels[labels.count - 2]) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    // MARK: Safari

    /// Safari's `Cookies.binarycookies`: a big-endian page table, then little-endian pages of records.
    static func parseBinaryCookies(_ data: Data) throws -> [Cookie] {
        let bytes = [UInt8](data)
        func be32(_ at: Int) -> Int? {
            guard at + 4 <= bytes.count else { return nil }
            return Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
        }
        func le32(_ at: Int) -> Int? {
            guard at >= 0, at + 4 <= bytes.count else { return nil }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        func double(_ at: Int) -> Double? {
            guard at >= 0, at + 8 <= bytes.count else { return nil }
            var raw: UInt64 = 0
            for i in 0..<8 { raw |= UInt64(bytes[at + i]) << (8 * UInt64(i)) }
            return Double(bitPattern: raw)
        }
        func string(_ at: Int, limit: Int) -> String {
            guard at >= 0, at < limit else { return "" }
            var end = at
            while end < limit, bytes[end] != 0 { end += 1 }
            return String(decoding: bytes[at..<end], as: UTF8.self)
        }

        guard bytes.count >= 8, bytes[0..<4].elementsEqual("cook".utf8), let pageCount = be32(4) else {
            throw Failure.unreadable("not a Safari cookie file")
        }
        var sizes: [Int] = []
        for i in 0..<pageCount {
            guard let size = be32(8 + 4 * i) else { throw Failure.unreadable("truncated page table") }
            sizes.append(size)
        }
        var cookies: [Cookie] = []
        var page = 8 + 4 * pageCount
        for size in sizes {
            defer { page += size }
            let pageEnd = min(page + size, bytes.count)
            guard let count = le32(page + 4) else { break }
            for i in 0..<count {
                guard let offset = le32(page + 8 + 4 * i) else { break }
                let at = page + offset
                guard let length = le32(at), let flags = le32(at + 8),
                      let domainAt = le32(at + 16), let nameAt = le32(at + 20),
                      let pathAt = le32(at + 24), let valueAt = le32(at + 28),
                      let expiry = double(at + 40) else { continue }
                let end = min(at + length, pageEnd)
                cookies.append(Cookie(
                    domain: string(at + domainAt, limit: end), name: string(at + nameAt, limit: end),
                    value: string(at + valueAt, limit: end), path: string(at + pathAt, limit: end),
                    expires: expiry > 0 ? Date(timeIntervalSinceReferenceDate: expiry) : nil,
                    secure: flags & 1 != 0, httpOnly: flags & 4 != 0, sameSite: nil))
            }
        }
        return cookies
    }

    // MARK: Chromium

    /// Derived keys by Keychain service, so a launch asks the Keychain once per browser.
    private static var keys: [String: Data] = [:]
    private static let keysLock = NSLock()

    static func chromiumKey(service: String) throws -> Data {
        keysLock.lock(); defer { keysLock.unlock() }
        if let key = keys[service] { return key }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let password = result as? Data else {
            throw Failure.keychainRefused(service)
        }
        let key = deriveChromiumKey(password: password)
        keys[service] = key
        return key
    }

    /// PBKDF2-SHA1, salt "saltysalt", 1003 rounds, 16 bytes: Chromium's macOS cookie key.
    static func deriveChromiumKey(password: Data) -> Data {
        var key = Data(count: 16)
        let salt = Array("saltysalt".utf8)
        key.withUnsafeMutableBytes { out in
            password.withUnsafeBytes { pass in
                _ = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), pass.baseAddress?.assumingMemoryBound(to: CChar.self),
                    password.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    out.baseAddress?.assumingMemoryBound(to: UInt8.self), 16)
            }
        }
        return key
    }

    /// AES-128-CBC with a 16-space IV, after a `v10`/`v11` tag. From cookie-database version 24 on, the
    /// plaintext starts with a 32-byte hash of the host, which is dropped.
    static func decryptChromium(_ encrypted: Data, key: Data, databaseVersion: Int) -> String? {
        guard encrypted.count > 3 else { return nil }
        let tag = String(decoding: encrypted.prefix(3), as: UTF8.self)
        guard tag == "v10" || tag == "v11" else { return nil }
        let body = encrypted.dropFirst(3)
        let iv = [UInt8](repeating: 0x20, count: 16)
        var out = Data(count: body.count + kCCBlockSizeAES128)
        var moved = 0
        let capacity = out.count
        let status = out.withUnsafeMutableBytes { outBytes in
            body.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, iv, inBytes.baseAddress, body.count,
                            outBytes.baseAddress, capacity, &moved)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        var plain = out.prefix(moved)
        if databaseVersion >= 24 { plain = plain.dropFirst(min(32, plain.count)) }
        return String(data: Data(plain), encoding: .utf8)
    }

    /// Microseconds since 1601 → a date; 0 means a session cookie.
    static func chromiumDate(_ micros: Int64) -> Date? {
        guard micros > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(micros) / 1_000_000 - 11_644_473_600)
    }

    static func readChromium(_ file: URL, domain: String, key: Data) throws -> [Cookie] {
        try withCopy(of: file) { db in
            var version = 0
            try query(db, "SELECT value FROM meta WHERE key = 'version'", []) { row in
                version = Int(row.text(0)) ?? 0
            }
            var cookies: [Cookie] = []
            try query(db, """
                SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite
                FROM cookies WHERE host_key = ?1 OR host_key = ?2 OR host_key LIKE ?3
                """, [domain, "." + domain, "%." + domain]) { row in
                let encrypted = row.blob(3)
                let value = encrypted.isEmpty
                    ? row.text(2)
                    : decryptChromium(encrypted, key: key, databaseVersion: version)
                guard let value else { return }
                let sameSite: HTTPCookieStringPolicy? = switch row.int(8) {
                case 1: .sameSiteLax
                case 2: .sameSiteStrict
                default: nil
                }
                cookies.append(Cookie(
                    domain: row.text(0), name: row.text(1), value: value, path: row.text(4),
                    expires: chromiumDate(row.int(5)), secure: row.int(6) != 0, httpOnly: row.int(7) != 0,
                    sameSite: sameSite))
            }
            return cookies
        }
    }

    // MARK: Firefox

    static func readFirefox(_ file: URL, domain: String) throws -> [Cookie] {
        try withCopy(of: file) { db in
            var cookies: [Cookie] = []
            try query(db, """
                SELECT host, name, value, path, expiry, isSecure, isHttpOnly, sameSite FROM moz_cookies
                WHERE host = ?1 OR host = ?2 OR host LIKE ?3
                """, [domain, "." + domain, "%." + domain]) { row in
                // Seconds until Firefox 133, milliseconds after.
                let raw = Double(row.int(4))
                let seconds = raw > 100_000_000_000 ? raw / 1000 : raw
                let sameSite: HTTPCookieStringPolicy? = switch row.int(7) {
                case 1: .sameSiteLax
                case 2: .sameSiteStrict
                default: nil
                }
                cookies.append(Cookie(
                    domain: row.text(0), name: row.text(1), value: row.text(2), path: row.text(3),
                    expires: seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil,
                    secure: row.int(5) != 0, httpOnly: row.int(6) != 0, sameSite: sameSite))
            }
            return cookies
        }
    }

    // MARK: SQLite

    struct Row {
        let statement: OpaquePointer
        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func blob(_ column: Int32) -> Data {
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: bytes, count: count)
        }
    }

    /// Open a copy of a browser's database, write-ahead log included: the browser holds a lock on the
    /// original while it runs, and recent cookies may still be in the log.
    static func withCopy<T>(of file: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: "folio-cookie-import-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let copy = folder.appending(path: "cookies.db")
        do {
            try fm.copyItem(at: file, to: copy)
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw Failure.needsFullDiskAccess
        }
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: file.path + suffix)
            if fm.fileExists(atPath: side.path) {
                try? fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw Failure.unreadable("couldn't open \(file.lastPathComponent)")
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    static func query(_ db: OpaquePointer, _ sql: String, _ arguments: [String], row: (Row) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, argument) in arguments.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), argument, -1, transient)
        }
        while sqlite3_step(statement) == SQLITE_ROW { try row(Row(statement: statement)) }
    }

    // MARK: Into a card's jar

    /// Read `source` for `host`'s registrable domain and set what it holds into `store`. Returns how
    /// many cookies were copied.
    @MainActor
    static func copy(from source: Source, host: String, into store: WKWebsiteDataStore) async throws -> Int {
        let domain = registrableDomain(of: host)
        let cookies = try await Task.detached { try read(source, domain: domain) }.value
        let now = Date()
        var copied = 0
        for cookie in cookies where (cookie.expires ?? .distantFuture) > now {
            guard let made = cookie.httpCookie else { continue }
            await store.httpCookieStore.setCookie(made)
            copied += 1
        }
        Log.write("canvas cookie import: \(copied) cookie(s) for \(domain) from \(source.title)")
        return copied
    }
}
