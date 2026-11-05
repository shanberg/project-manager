import CommonCrypto
import SQLite3
import WebKit
import XCTest

/// Reading other browsers' cookie files: Safari's binary format, Chromium's encrypted SQLite and
/// Firefox's plain one, each built here by hand so nothing on this Mac is touched.
final class CanvasCookieImportTests: XCTestCase {
    typealias Import = CanvasCookieImport

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "cookie-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Domains

    func testRegistrableDomain() {
        XCTAssertEqual(Import.registrableDomain(of: "music.apple.com"), "apple.com")
        XCTAssertEqual(Import.registrableDomain(of: "apple.com"), "apple.com")
        XCTAssertEqual(Import.registrableDomain(of: "a.b.example.co.uk"), "example.co.uk")
        XCTAssertEqual(Import.registrableDomain(of: "localhost"), "localhost")
    }

    func testMatchesDomainAndSubdomainsOnly() {
        XCTAssertTrue(Import.matches(".apple.com", "apple.com"))
        XCTAssertTrue(Import.matches("music.apple.com", "apple.com"))
        XCTAssertTrue(Import.matches("apple.com", "apple.com"))
        XCTAssertFalse(Import.matches("notapple.com", "apple.com"))
        XCTAssertFalse(Import.matches("apple.com.evil.net", "apple.com"))
    }

    // MARK: Safari

    func testParsesSafariBinaryCookiesAcrossPages() throws {
        let expires = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let data = binaryCookies(pages: [
            [("music.apple.com", "media-user-token", "abc", "/", 5, expires)],
            [(".apple.com", "myacinfo", "xyz", "/", 1, expires), ("example.com", "other", "1", "/x", 0, nil)],
        ])
        let cookies = try Import.parseBinaryCookies(data)
        XCTAssertEqual(cookies.count, 3)
        XCTAssertEqual(cookies[0], Import.Cookie(
            domain: "music.apple.com", name: "media-user-token", value: "abc", path: "/",
            expires: expires, secure: true, httpOnly: true, sameSite: nil))
        XCTAssertEqual(cookies[1].domain, ".apple.com")
        XCTAssertTrue(cookies[1].secure)
        XCTAssertFalse(cookies[1].httpOnly)
        XCTAssertNil(cookies[2].expires)
        XCTAssertEqual(cookies[2].path, "/x")
    }

    func testRejectsAFileThatIsNotSafaris() {
        XCTAssertThrowsError(try Import.parseBinaryCookies(Data("SQLite format 3".utf8)))
    }

    func testReadsOnlyTheDomainFromSafari() throws {
        let file = folder.appending(path: "Cookies.binarycookies")
        try binaryCookies(pages: [[
            (".apple.com", "a", "1", "/", 0, nil), ("example.com", "b", "2", "/", 0, nil),
        ]]).write(to: file)
        let cookies = try Import.read(.init(title: "Safari", kind: .safari(file)), domain: "apple.com")
        XCTAssertEqual(cookies.map(\.name), ["a"])
    }

    // MARK: Chromium

    func testDecryptsChromiumValuesBeforeAndAfterTheHostHash() {
        let key = Import.deriveChromiumKey(password: Data("peanuts".utf8))
        XCTAssertEqual(key.count, 16)
        let old = chromiumEncrypt("secret", key: key, hashPrefix: false)
        XCTAssertEqual(Import.decryptChromium(old, key: key, databaseVersion: 23), "secret")
        let new = chromiumEncrypt("secret", key: key, hashPrefix: true)
        XCTAssertEqual(Import.decryptChromium(new, key: key, databaseVersion: 24), "secret")
        XCTAssertNil(Import.decryptChromium(Data("plain".utf8), key: key, databaseVersion: 24))
    }

    func testChromiumEpoch() {
        XCTAssertNil(Import.chromiumDate(0))
        // 1970-01-01 in microseconds since 1601.
        XCTAssertEqual(Import.chromiumDate(11_644_473_600_000_000), Date(timeIntervalSince1970: 0))
    }

    func testReadsAChromiumDatabase() throws {
        let key = Import.deriveChromiumKey(password: Data("pw".utf8))
        let file = folder.appending(path: "Cookies")
        try sqlite(file, [
            "CREATE TABLE meta (key TEXT, value TEXT)",
            "INSERT INTO meta VALUES ('version', '24')",
            """
            CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT,
              expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, samesite INTEGER)
            """,
        ]) { db in
            let insert = "INSERT INTO cookies VALUES (?, ?, ?, ?, '/', 13500000000000000, 1, 1, 1)"
            for (host, name, plain, encrypted) in [
                (".apple.com", "myacinfo", "", chromiumEncrypt("tok", key: key, hashPrefix: true)),
                ("music.apple.com", "plain", "visible", Data()),
                ("example.com", "other", "", chromiumEncrypt("no", key: key, hashPrefix: true)),
            ] {
                var statement: OpaquePointer?
                sqlite3_prepare_v2(db, insert, -1, &statement, nil)
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(statement, 1, host, -1, transient)
                sqlite3_bind_text(statement, 2, name, -1, transient)
                sqlite3_bind_text(statement, 3, plain, -1, transient)
                _ = encrypted.withUnsafeBytes {
                    sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(encrypted.count), transient)
                }
                XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
                sqlite3_finalize(statement)
            }
        }
        let cookies = try Import.readChromium(file, domain: "apple.com", key: key)
        XCTAssertEqual(Set(cookies.map(\.name)), ["myacinfo", "plain"])
        let token = try XCTUnwrap(cookies.first { $0.name == "myacinfo" })
        XCTAssertEqual(token.value, "tok")
        XCTAssertEqual(token.sameSite, .sameSiteLax)
        XCTAssertTrue(token.secure && token.httpOnly)
        XCTAssertNotNil(token.expires)
    }

    func testListsChromiumProfilesByTheirNames() throws {
        let root = folder.appending(path: "Chrome")
        for dir in ["Default", "Profile 1/Network"] {
            try FileManager.default.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appending(path: "Default/Cookies"))
        try Data().write(to: root.appending(path: "Profile 1/Network/Cookies"))
        try FileManager.default.createDirectory(at: root.appending(path: "System Profile"), withIntermediateDirectories: true)
        try Data(#"{"profile":{"info_cache":{"Default":{"name":"Personal"},"Profile 1":{"name":"Work"}}}}"#.utf8)
            .write(to: root.appending(path: "Local State"))
        let profiles = Import.chromiumProfiles(root: root)
        XCTAssertEqual(profiles.map(\.name), ["Personal", "Work"])
        XCTAssertEqual(profiles[1].cookies.lastPathComponent, "Cookies")
    }

    // MARK: Firefox

    func testReadsAFirefoxDatabase() throws {
        let root = folder.appending(path: "Firefox")
        let profile = root.appending(path: "Profiles/abc.default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try "[Profile0]\nName=default\nIsRelative=1\nPath=Profiles/abc.default\n"
            .write(to: root.appending(path: "profiles.ini"), atomically: true, encoding: .utf8)
        try sqlite(profile.appending(path: "cookies.sqlite"), [
            """
            CREATE TABLE moz_cookies (host TEXT, name TEXT, value TEXT, path TEXT, expiry INTEGER,
              isSecure INTEGER, isHttpOnly INTEGER, sameSite INTEGER)
            """,
            "INSERT INTO moz_cookies VALUES ('.apple.com', 's', 'v', '/', 2000000000, 1, 0, 2)",
            "INSERT INTO moz_cookies VALUES ('.apple.com', 'ms', 'v', '/', 2000000000000, 0, 0, 0)",
            "INSERT INTO moz_cookies VALUES ('example.com', 'x', 'v', '/', 2000000000, 0, 0, 0)",
        ])
        let profiles = Import.firefoxProfiles(root: root)
        XCTAssertEqual(profiles.map(\.title), ["Firefox"])
        let cookies = try Import.readFirefox(profiles[0].cookies, domain: "apple.com")
        XCTAssertEqual(cookies.map(\.name), ["s", "ms"])
        XCTAssertEqual(cookies[0].expires, Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(cookies[1].expires, Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(cookies[0].sameSite, .sameSiteStrict)
    }

    // MARK: Into a jar

    @MainActor
    func testCopiesLiveCookiesIntoAStoreAndSkipsExpiredOnes() async throws {
        let file = folder.appending(path: "Cookies.binarycookies")
        let future = Date().addingTimeInterval(3600)
        try binaryCookies(pages: [[
            (".apple.com", "live", "1", "/", 1, future),
            (".apple.com", "gone", "2", "/", 1, Date(timeIntervalSinceReferenceDate: 1)),
        ]]).write(to: file)
        let store = WKWebsiteDataStore.nonPersistent()
        let copied = try await Import.copy(
            from: .init(title: "Safari", kind: .safari(file)), host: "music.apple.com", into: store)
        XCTAssertEqual(copied, 1)
        let names = await store.httpCookieStore.allCookies().map(\.name)
        XCTAssertEqual(names, ["live"])
    }

    // MARK: Builders

    private typealias Record = (domain: String, name: String, value: String, path: String, flags: UInt32, expires: Date?)

    /// Safari's format: "cook", page count and sizes big-endian, then pages of little-endian records.
    private func binaryCookies(pages: [[Record]]) -> Data {
        func le(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        func be(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
        func ledouble(_ v: Double) -> [UInt8] { withUnsafeBytes(of: v.bitPattern.littleEndian, Array.init) }

        let built: [[UInt8]] = pages.map { records in
            let encoded: [[UInt8]] = records.map { r in
                let strings = [r.domain, r.name, r.path, r.value].map { Array($0.utf8) + [0] }
                var offset = UInt32(56)
                var offsets: [UInt32] = []
                for s in strings { offsets.append(offset); offset += UInt32(s.count) }
                var body = le(offset) + le(0) + le(r.flags) + le(0)
                body += offsets.flatMap(le) + [UInt8](repeating: 0, count: 8)
                body += ledouble(r.expires?.timeIntervalSinceReferenceDate ?? 0) + ledouble(0)
                return body + strings.flatMap { $0 }
            }
            var page = be(0x100) + le(UInt32(records.count))
            var at = UInt32(8 + 4 * records.count + 4)
            for record in encoded { page += le(at); at += UInt32(record.count) }
            page += le(0)
            return page + encoded.flatMap { $0 }
        }
        var file = Array("cook".utf8) + be(UInt32(pages.count)) + built.map { be(UInt32($0.count)) }.flatMap { $0 }
        file += built.flatMap { $0 }
        return Data(file)
    }

    private func chromiumEncrypt(_ plain: String, key: Data, hashPrefix: Bool) -> Data {
        let input = (hashPrefix ? Data(repeating: 7, count: 32) : Data()) + Data(plain.utf8)
        var out = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let capacity = out.count
        let iv = [UInt8](repeating: 0x20, count: 16)
        _ = out.withUnsafeMutableBytes { o in
            input.withUnsafeBytes { i in
                key.withUnsafeBytes { k in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, key.count, iv, i.baseAddress, input.count, o.baseAddress, capacity, &moved)
                }
            }
        }
        return Data("v10".utf8) + out.prefix(moved)
    }

    private func sqlite(_ file: URL, _ statements: [String], then body: (OpaquePointer) -> Void = { _ in }) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for sql in statements { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql) }
        body(db!)
    }
}
