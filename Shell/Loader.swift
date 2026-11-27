import Foundation
import Security
import UIKit

/// Runs the test: download a dylib, sign it on this phone, load it with dlopen.
@MainActor
final class Loader: ObservableObject {
    @Published var lines: [String] = []
    @Published var keySummary = "No signing key imported yet"
    @Published var payloadURL: String
    @Published var busy = false
    @Published var loadedHello: String?

    private var handle: UnsafeMutableRawPointer?
    private let fm = FileManager.default
    private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var workDir: URL { docs.appendingPathComponent("payload", isDirectory: true) }
    private var downloaded: URL { workDir.appendingPathComponent("downloaded.dylib") }
    private var logFile: URL { docs.appendingPathComponent("loader-test-log.txt") }

    init() {
        let fromPlist = Bundle.main.object(forInfoDictionaryKey: "PayloadURL") as? String ?? ""
        payloadURL = UserDefaults.standard.string(forKey: "payloadURL")
            ?? (fromPlist.hasPrefix("http") ? fromPlist : "")
        try? fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        if let previous = try? String(contentsOf: logFile, encoding: .utf8), !previous.isEmpty {
            lines = ["── log from earlier runs (kept in case a test crashed the app) ──"]
                + previous.split(separator: "\n").map(String.init)
                + ["── this launch ──"]
        }
        log("Shell \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?"), iOS \(UIDevice.current.systemVersion)")
        // Testing aid (simulator, or Files on a device): a key file dropped into Documents
        // as import-key.json / .p12 / .pem is imported once, then deleted.
        for name in ["import-key.json", "import-key.p12", "import-key.pem"] {
            let u = docs.appendingPathComponent(name)
            if fm.fileExists(atPath: u.path) { importKey(from: u, password: ""); try? fm.removeItem(at: u) }
        }
        refreshKeySummary()
        log(Profile.summary())
        if ProcessInfo.processInfo.arguments.contains("-autorun") {
            Task { await runAll() }
        }
    }

    // MARK: logging (written to disk at once, so it survives a crash)

    func log(_ s: String) {
        lines.append(s)
        let line = "[\(Self.time.string(from: Date()))] \(s)\n"
        if let h = try? FileHandle(forWritingTo: logFile) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.synchronize(); try? h.close()
        } else {
            try? Data(line.utf8).write(to: logFile)
        }
    }
    func clearLog() { lines = []; try? fm.removeItem(at: logFile) }
    private static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    // MARK: signing key

    /// Accepts SideStep's cert-<appleid>.json, a .p12, or a PEM/DER private key.
    func importKey(from url: URL, password: String) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { log("❌ Could not read \(url.lastPathComponent)"); return }
        var key = data, cert: Data? = nil, kind = "key file"
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let k = (obj["key"] as? String).flatMap({ Data(base64Encoded: $0) }) {
            key = k
            cert = (obj["data"] as? String).flatMap { Data(base64Encoded: $0) }
            kind = "SideStep certificate file"
        } else if url.pathExtension.lowercased() == "p12" {
            kind = ".p12"
        }
        Keychain.set(key, "key"); Keychain.set(cert, "cert"); Keychain.set(Data(password.utf8), "password")
        log("✅ Imported \(kind) (\(url.lastPathComponent)), stored in this app's Keychain")
        refreshKeySummary()
    }
    func forgetKey() {
        Keychain.set(nil, "key"); Keychain.set(nil, "cert"); Keychain.set(nil, "password")
        log("Signing key removed from the Keychain"); refreshKeySummary()
    }
    private func refreshKeySummary() {
        guard let k = Keychain.get("key") else { keySummary = "No signing key imported yet"; return }
        keySummary = "Signing key imported (\(k.count) bytes\(Keychain.get("cert") != nil ? ", with certificate" : ""))"
    }

    // MARK: the test steps

    func runAll() async {
        busy = true; defer { busy = false }
        guard await download() else { return }
        _ = signAndLoad()
        log("Next: the control test. If iOS kills the app here, that also proves the point; reopen it to see the log.")
        loadUnsigned()
        log("Done.")
    }

    @discardableResult
    func download() async -> Bool {
        guard let url = URL(string: payloadURL), url.scheme?.hasPrefix("http") == true || url.isFileURL else {
            log("❌ Set the payload URL first"); return false
        }
        UserDefaults.standard.set(payloadURL, forKey: "payloadURL")
        if url.isFileURL {   // testing aid: a local file (simulator)
            do {
                try? fm.removeItem(at: downloaded)
                try fm.copyItem(at: url, to: downloaded)
                log("✅ Copied local payload \(url.lastPathComponent)")
                return true
            } catch { log("❌ \(error.localizedDescription)"); return false }
        }
        log("Downloading \(url.absoluteString)")
        do {
            var req = URLRequest(url: url); req.cachePolicy = .reloadIgnoringLocalCacheData
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { log("❌ HTTP \(code)"); return false }
            try? fm.removeItem(at: downloaded)
            try fm.moveItem(at: tmp, to: downloaded)
            let size = (try? fm.attributesOfItem(atPath: downloaded.path)[.size] as? Int) ?? 0
            log("✅ Downloaded \(size) bytes")
            return true
        } catch {
            log("❌ Download failed: \(error.localizedDescription)"); return false
        }
    }

    /// The real test: sign the download with the imported key, then dlopen it.
    @discardableResult
    func signAndLoad() -> Bool {
        guard fm.fileExists(atPath: downloaded.path) else { log("❌ Download the payload first"); return false }
        guard let key = Keychain.get("key") else { log("❌ Import your signing key first"); return false }
        guard let prov = Profile.path() else {
            log("❌ No provisioning profile: install this app with SideStep (or, in the simulator, put one in Documents/embedded.mobileprovision)"); return false
        }
        // A fresh file name each time: dyld caches by path, and the old image stays loaded.
        let target = workDir.appendingPathComponent("signed-\(UUID().uuidString.prefix(8)).dylib")
        let tmp = fm.temporaryDirectory
        let keyFile = tmp.appendingPathComponent("k-\(UUID().uuidString)")
        let certFile = tmp.appendingPathComponent("c-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: keyFile); try? fm.removeItem(at: certFile) }
        do {
            try fm.copyItem(at: downloaded, to: target)
            try key.write(to: keyFile, options: .completeFileProtection)
            if let c = Keychain.get("cert") { try c.write(to: certFile) }
        } catch { log("❌ Could not stage files: \(error.localizedDescription)"); return false }

        log("Signing on this phone with zsign…")
        let password = Keychain.get("password").flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var buf = [CChar](repeating: 0, count: 16384)
        let started = Date()
        let certPath: String? = fm.fileExists(atPath: certFile.path) ? certFile.path : nil
        let rc = withOptionalCString(certPath) { cert in
            sst_sign_macho(target.path, keyFile.path, cert, password, prov,
                           "com.sidestep.payload", &buf, buf.count)
        }
        let zlog = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
        if !zlog.isEmpty { zlog.split(separator: "\n").forEach { log("  zsign: \($0)") } }
        guard rc == 0 else { log("❌ Signing failed (code \(rc))"); return false }
        log(String(format: "✅ Signed in %.2fs", Date().timeIntervalSince(started)))
        return load(target, label: "signed")
    }

    /// Control: load the download as-is (it isn't signed by your certificate).
    /// iOS should refuse it; if it does, the signed test above is meaningful.
    func loadUnsigned() {
        guard fm.fileExists(atPath: downloaded.path) else { log("❌ Download the payload first"); return }
        let target = workDir.appendingPathComponent("unsigned-\(UUID().uuidString.prefix(8)).dylib")
        do { try fm.copyItem(at: downloaded, to: target) } catch { log("❌ \(error.localizedDescription)"); return }
        if load(target, label: "unsigned (control)") {
            #if targetEnvironment(simulator)
            log("ℹ️ The simulator loaded the unsigned copy too: it doesn't enforce iOS code signing, so only a real device can answer the question.")
            #else
            log("⚠️ iOS loaded an unsigned dylib. Unexpected: tell Claude.")
            #endif
        } else {
            log("✅ As expected, iOS refused the unsigned copy")
        }
    }

    private func load(_ url: URL, label: String) -> Bool {
        log("dlopen \(label): \(url.lastPathComponent)")
        guard let h = dlopen(url.path, RTLD_NOW) else {
            let err = dlerror().map { String(cString: $0) } ?? "unknown error"
            log("❌ dlopen refused the \(label) copy: \(err)")
            return false
        }
        log("✅ dlopen accepted the \(label) copy")
        guard let sym = dlsym(h, "sidestep_payload_hello") else {
            log("❌ Loaded, but sidestep_payload_hello is missing"); return true
        }
        typealias Hello = @convention(c) () -> UnsafePointer<CChar>?
        let hello = unsafeBitCast(sym, to: Hello.self)().map { String(cString: $0) } ?? "(nil)"
        log("🎉 Payload says: \(hello)")
        if label == "signed" { handle = h; loadedHello = hello }
        return true
    }

    /// A screen built by the downloaded code.
    func payloadViewController() -> UIViewController? {
        guard let h = handle, let sym = dlsym(h, "sidestep_payload_make_view_controller") else { return nil }
        typealias Make = @convention(c) () -> UnsafeMutableRawPointer?
        guard let p = unsafeBitCast(sym, to: Make.self)() else { return nil }
        return Unmanaged<UIViewController>.fromOpaque(p).takeRetainedValue()
    }
}

private func withOptionalCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let s else { return body(nil) }
    return s.withCString { body($0) }
}

// MARK: - The app's own provisioning profile

enum Profile {
    /// The app's own profile (SideStep embeds it), else Documents/embedded.mobileprovision (simulator).
    static func path() -> String? {
        if let p = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") { return p }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let p = docs.appendingPathComponent("embedded.mobileprovision").path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }
    static func plist() -> [String: Any]? {
        guard let path = path(),
              let data = FileManager.default.contents(atPath: path),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        return try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound],
                                                           format: nil) as? [String: Any]
    }
    static func summary() -> String {
        guard let p = plist() else { return "No provisioning profile in this app (not installed by SideStep?)" }
        let team = (p["TeamIdentifier"] as? [String])?.first ?? "?"
        let certs = (p["DeveloperCertificates"] as? [Data])?.count ?? 0
        let exp = (p["ExpirationDate"] as? Date).map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "?"
        return "Profile: team \(team), \(certs) certificate(s), expires \(exp)"
    }
}

// MARK: - Minimal Keychain storage

enum Keychain {
    private static let service = "com.sidestep.loadertest"
    static func set(_ data: Data?, _ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard let data else { return }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    static func get(_ account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
}
