import AppKit
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.timwheeler.stoplight", category: "Updater")

/// Sparkle-lite (US-020). Checks GitHub Releases, downloads the notarized zip, verifies it with
/// Gatekeeper, swaps the bundle in place, relaunches. Unsandboxed, so no helper tool needed.
@MainActor
@Observable
final class Updater {
    struct Release: Equatable {
        let version: String
        let zipURL: URL
        let pageURL: URL
    }
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading
        case installing
        case failed(String)
    }

    static let repo = "timmywheels/stoplight"
    static let checkInterval: TimeInterval = 6 * 60 * 60

    private(set) var latest: Release?
    private(set) var state: State = .idle
    private(set) var lastCheck: Date?

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var updateAvailable: Bool { latest.map { Self.isNewer($0.version, than: currentVersion) } ?? false }

    /// Called from the poll loop; cheap when recently checked.
    func checkIfDue() async {
        if let last = lastCheck, Date.now.timeIntervalSince(last) < Self.checkInterval { return }
        await check()
    }

    func check() async {
        state = .checking
        defer { lastCheck = .now }
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("Stoplight/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: req)
            struct R: Decodable {
                struct Asset: Decodable { let name: String; let browser_download_url: URL }
                let tag_name: String
                let html_url: URL
                let assets: [Asset]
            }
            let r = try JSONDecoder().decode(R.self, from: data)
            guard let zip = r.assets.first(where: { $0.name.hasSuffix(".zip") }) else { throw Err.noAsset }
            let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
            latest = Release(version: version, zipURL: zip.browser_download_url, pageURL: r.html_url)
            state = updateAvailable ? .available : .upToDate
        } catch {
            log.error("check failed: \(String(describing: error), privacy: .public)")
            state = .failed("Couldn't check for updates")
        }
    }

    /// Download → verify → replace → relaunch.
    func install() async {
        guard let release = latest, updateAvailable else { return }
        state = .downloading
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("stoplight-update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let (file, _) = try await URLSession.shared.download(from: release.zipURL)
            let zip = tmp.appendingPathComponent("Stoplight.zip")
            try FileManager.default.moveItem(at: file, to: zip)

            state = .installing
            try run("/usr/bin/ditto", "-x", "-k", zip.path, tmp.path)
            let newApp = tmp.appendingPathComponent("Stoplight.app")
            guard FileManager.default.fileExists(atPath: newApp.path) else { throw Err.badArchive }

            // Refuse anything Gatekeeper wouldn't launch, and anything that isn't us.
            try run("/usr/sbin/spctl", "--assess", "--type", "execute", newApp.path)
            let newID = Bundle(url: newApp)?.bundleIdentifier
            guard newID == Bundle.main.bundleIdentifier else { throw Err.wrongBundle }

            let current = Bundle.main.bundleURL
            // Trash the running bundle (allowed: the binary stays mapped), then move the new one in.
            try FileManager.default.trashItem(at: current, resultingItemURL: nil)
            try FileManager.default.moveItem(at: newApp, to: current)
            try? FileManager.default.removeItem(at: tmp)

            log.notice("installed \(release.version, privacy: .public); relaunching")
            relaunch(current)
        } catch {
            log.error("install failed: \(String(describing: error), privacy: .public)")
            try? FileManager.default.removeItem(at: tmp)
            state = .failed(error.localizedDescription)
        }
    }

    private func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(app.path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func run(_ exe: String, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Err.command(exe, p.terminationStatus) }
    }

    enum Err: LocalizedError {
        case noAsset, badArchive, wrongBundle, command(String, Int32)
        var errorDescription: String? {
            switch self {
            case .noAsset: "Release has no zip asset"
            case .badArchive: "Downloaded archive didn't contain Stoplight.app"
            case .wrongBundle: "Downloaded app has a different bundle identifier"
            case .command(let c, let code): "\(URL(fileURLWithPath: c).lastPathComponent) failed (\(code)). The update was not installed."
            }
        }
    }

    /// Numeric dotted compare. "0.10.0" > "0.9.1".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let (x, y) = (i < pa.count ? pa[i] : 0, i < pb.count ? pb[i] : 0)
            if x != y { return x > y }
        }
        return false
    }
}
