import Foundation
import Security

/// Runs a command-line tool and captures its output. Arguments go straight to the process
/// (never through a shell), and anything listed in `redact` is masked in the returned text.
enum Shell {
    struct Output {
        let status: Int32
        let out: String
        let err: String
        var ok: Bool { status == 0 }
    }

    private final class Box: @unchecked Sendable { var data = Data() }

    @discardableResult
    static func run(_ exe: String, _ args: [String], redact: [String] = []) -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        do { try p.run() } catch {
            return Output(status: -1, out: "", err: error.localizedDescription)
        }
        let errBox = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errBox.data = e.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = o.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        func clean(_ d: Data) -> String {
            var s = String(decoding: d, as: UTF8.self)
            for r in redact where !r.isEmpty { s = s.replacingOccurrences(of: r, with: "•••") }
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Output(status: p.terminationStatus, out: clean(outData), err: clean(errBox.data))
    }
}

struct SigningError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A local code-signing identity kept in Harbor's own keychain. Signing every standalone app
/// with the same identity means macOS grants "Claude Safe Storage" access once and keeps it
/// across rebuilds. Nothing is added to the user's keychain search list or to system trust.
enum SigningIdentity {
    static let name = "Harbor Local Signing"
    static let service = "app.harbor.Harbor"
    static let account = "signing-keychain-password"
    static let security = "/usr/bin/security"
    static let openssl = "/usr/bin/openssl"

    static var keychainURL: URL { Paths.signingFolder.appendingPathComponent("signing.keychain-db") }

    struct Ready {
        let keychain: String
        let password: String
        /// True when a broken identity was thrown away and made again.
        let recreated: Bool
    }

    /// Returns a working identity, creating it the first time and repairing it if it's broken.
    static func ensure() throws -> Ready {
        let fm = FileManager.default
        let stored = readPassword()
        if let pw = stored, fm.fileExists(atPath: keychainURL.path), isUsable(password: pw) {
            return Ready(keychain: keychainURL.path, password: pw, recreated: false)
        }
        let hadAnything = stored != nil || fm.fileExists(atPath: Paths.signingFolder.path)
        reset()
        let pw = try create()
        return Ready(keychain: keychainURL.path, password: pw, recreated: hadAnything)
    }

    /// Deletes the signing keychain and its stored password.
    static func reset() {
        try? FileManager.default.removeItem(at: Paths.signingFolder)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }

    static func unlock(_ ready: Ready) -> Bool {
        Shell.run(security, ["unlock-keychain", "-p", ready.password, ready.keychain],
                  redact: [ready.password]).ok
    }

    private static func isUsable(password: String) -> Bool {
        let kc = keychainURL.path
        guard Shell.run(security, ["unlock-keychain", "-p", password, kc], redact: [password]).ok else { return false }
        let found = Shell.run(security, ["find-identity", "-p", "codesigning", kc])
        return found.ok && found.out.contains(name)
    }

    // MARK: Keychain password (stored in the login keychain)

    private static func readPassword() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func storePassword(_ pw: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(pw.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SigningError(message: "Couldn't save the signing password to your keychain (error \(status)).")
        }
    }

    private static func randomBytes(_ n: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: n)
        guard SecRandomCopyBytes(kSecRandomDefault, n, &bytes) == errSecSuccess else {
            throw SigningError(message: "Couldn't generate random bytes.")
        }
        return bytes
    }

    // MARK: Creation

    private static func create() throws -> String {
        let fm = FileManager.default
        let pw = Data(try randomBytes(32)).base64EncodedString()
        try storePassword(pw)

        try fm.createDirectory(at: Paths.signingFolder, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let kc = keychainURL.path
        try require(Shell.run(security, ["create-keychain", "-p", pw, kc], redact: [pw]), "create the signing keychain")
        // No auto-lock timeout. The keychain is deliberately not added to the search list.
        try require(Shell.run(security, ["set-keychain-settings", kc]), "configure the signing keychain")

        let tmp = fm.temporaryDirectory.appendingPathComponent("harbor-sign-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: tmp) }

        let p12pw = try randomBytes(16).map { String(format: "%02x", $0) }.joined()
        let config = """
        [req]
        distinguished_name = dn
        x509_extensions = ext
        prompt = no
        [dn]
        CN = \(name)
        [ext]
        basicConstraints = critical,CA:false
        keyUsage = critical,digitalSignature
        extendedKeyUsage = critical,codeSigning

        """
        let cfg = tmp.appendingPathComponent("openssl.cnf")
        try config.write(to: cfg, atomically: true, encoding: .utf8)
        let key = tmp.appendingPathComponent("key.pem").path
        let cert = tmp.appendingPathComponent("cert.pem").path
        let p12 = tmp.appendingPathComponent("id.p12").path

        try require(Shell.run(openssl, ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650",
                                        "-keyout", key, "-out", cert, "-config", cfg.path]),
                    "create the signing certificate")

        // Newer OpenSSL writes .p12 files that `security import` rejects. Try the old format if so.
        let variants: [[String]] = [[], ["-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"],
                                    ["-legacy"]]
        var imported = false
        var lastError = ""
        _ = Shell.run(security, ["unlock-keychain", "-p", pw, kc], redact: [pw])
        for extra in variants {
            try? fm.removeItem(atPath: p12)
            let export = Shell.run(openssl, ["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12,
                                             "-passout", "pass:\(p12pw)", "-name", name] + extra,
                                   redact: [p12pw])
            guard export.ok else { lastError = export.err; continue }
            let imp = Shell.run(security, ["import", p12, "-k", kc, "-P", p12pw, "-T", "/usr/bin/codesign"],
                                redact: [p12pw, pw])
            if imp.ok { imported = true; break }
            lastError = imp.err
        }
        guard imported else { throw SigningError(message: "Couldn't import the signing certificate. \(lastError)") }

        try require(Shell.run(security, ["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                                         "-s", "-k", pw, kc], redact: [pw]),
                    "allow codesign to use the signing key")

        let found = Shell.run(security, ["find-identity", "-p", "codesigning", kc])
        guard found.ok, found.out.contains(name) else {
            throw SigningError(message: "The signing certificate isn't in the signing keychain.")
        }
        return pw
    }

    private static func require(_ r: Shell.Output, _ what: String) throws {
        guard r.ok else { throw SigningError(message: "Couldn't \(what). \(r.err)") }
    }
}
