import Foundation
import Security

/// US-001. Order: `gh auth token` (memory only) → Keychain (pasted PAT). Never writes the gh token anywhere.
enum TokenSource {
    enum Kind: String, Equatable { case gh = "gh CLI", keychain = "Token" }
    struct Found { let token: String; let kind: Kind }

    private static let service = "com.timwheeler.stoplight"
    private static let account = "github-token"
    private static let ghCandidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/opt/local/bin/gh", "/usr/bin/gh"]
    /// Set in Settings when `gh` lives somewhere unusual (a custom Homebrew prefix, for example).
    static var customGHPath: String {
        get { UserDefaults.standard.string(forKey: Prefs.ghPath) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Prefs.ghPath) }
    }
    /// Whatever a login shell resolves `gh` to. Filled once at launch, since the app's own PATH is minimal.
    private(set) nonisolated(unsafe) static var discoveredGHPath: String?

    /// Looks along your login shell's PATH ourselves rather than asking `command -v gh`, which answers
    /// with the alias when your config wraps gh (1Password's shell plugin does) instead of the file.
    static func discoverGH() async {
        if let path = await AgentLauncher.which("gh") { discoveredGHPath = path }
    }

    static func resolve() -> Found? {
        if let t = fromGH() { return Found(token: t, kind: .gh) }
        if let t = fromKeychain() { return Found(token: t, kind: .keychain) }
        return nil
    }

    /// Explicit setting, then whatever a login shell found, then the usual locations, then our own PATH.
    static func ghPath() -> String? {
        let custom = customGHPath.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty {
            // Accept a directory as well as the binary itself.
            let file = custom.hasSuffix("/gh") ? custom : (custom as NSString).appendingPathComponent("gh")
            if FileManager.default.isExecutableFile(atPath: file) { return file }
            if FileManager.default.isExecutableFile(atPath: custom) { return custom }
        }
        if let d = discoveredGHPath, FileManager.default.isExecutableFile(atPath: d) { return d }
        for p in ghCandidates where FileManager.default.isExecutableFile(atPath: p) { return p }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let p = "\(dir)/gh"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func fromGH() -> String? {
        guard let gh = ghPath() else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: gh)
        proc.arguments = ["auth", "token"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    // MARK: Keychain

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func fromKeychain() -> String? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func storeInKeychain(_ token: String) {
        clearKeychain()
        var q = baseQuery
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(q as CFDictionary, nil)
    }

    static func clearKeychain() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
