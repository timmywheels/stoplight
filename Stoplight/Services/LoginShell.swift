import Foundation

/// Your login shell, so what Stoplight runs sees the PATH your terminal does: `gh` wherever your
/// rc files put it (Homebrew, nix, mise, a custom prefix).
enum LoginShell {
    /// The PATH your login shell ends up with after all your rc files, then the usual tool folders.
    /// Asked once and kept; an empty answer (a config that hangs) is asked again next time.
    static func searchPath() async -> [String] {
        if cachedLoginPath == nil, let p = await loginPATH(), !p.isEmpty { cachedLoginPath = p }
        var seen = Set<String>()
        return ((cachedLoginPath ?? []) + extraPath.split(separator: ":").map(String.init)).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    private nonisolated(unsafe) static var cachedLoginPath: [String]?

    /// The first `name` on `searchPath()`: a real file, never an alias or a function your config wraps it in.
    static func which(_ name: String) async -> String? {
        for dir in await searchPath() where FileManager.default.isExecutableFile(atPath: "\(dir)/\(name)") { return "\(dir)/\(name)" }
        return nil
    }

    /// `printenv PATH` after a marker: anything your config prints on startup comes before it and is skipped.
    /// printenv, not `echo $PATH`, because fish keeps PATH as a list and only the exported form has colons.
    private static func loginPATH() async -> [String]? {
        let marker = "__STOPLIGHT_PATH__"
        guard let out = try? await shell("echo \(marker); printenv PATH") else { return nil }
        guard let after = out.components(separatedBy: marker).last else { return nil }
        let line = after.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.split(separator: ":").map(String.init)
    }

    struct ShellError: Error { let output: String }

    /// Common install dirs that may only be on PATH via .zshrc; searched after the login PATH.
    nonisolated static var extraPath: String {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.nix-profile/bin"].joined(separator: ":")
    }

    /// The account's real login shell, with the flags that make it read the user's config.
    /// zsh and bash need `-i` for .zshrc/.bashrc; fish reads config.fish on `-l` and rejects `-i` here.
    nonisolated static var loginShell: (path: String, args: [String]) {
        var path = "/bin/zsh"
        if let pw = getpwuid(getuid())?.pointee.pw_shell { path = String(cString: pw) }
        if !FileManager.default.isExecutableFile(atPath: path) { path = "/bin/zsh" }
        switch (path as NSString).lastPathComponent {
        case "zsh", "bash", "ksh": return (path, ["-ilc"])
        case "fish": return (path, ["-l", "-c"])
        default: return (path, ["-lc"])
        }
    }

    /// Runs under the user's own login shell so their config applies, whatever shell that is.
    /// Extra tool dirs go in the environment rather than an `export` line, since that syntax isn't
    /// portable (fish would reject it) and every shell inherits and extends PATH from its parent.
    @discardableResult
    static func shell(_ script: String) async throws -> String {
        try await Task.detached {
            let sh = loginShell
            let p = Process()
            p.executableURL = URL(fileURLWithPath: sh.path)
            p.arguments = sh.args + [script]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = extraPath + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            env["TERM"] = "dumb"   // keep prompt frameworks quiet in a non-tty shell
            // Separate pipes: an interactive login shell complains about zle and job control in a
            // non-tty ("can't change option: zle"), and that noise is not this command's output.
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            try p.run()
            // A login shell runs the user's whole config, and some of it waits forever without a
            // terminal. Give up after 15s (a slow one, nvm plus conda on a cold start, still finishes);
            // killing it closes the pipes, so the reads below return.
            let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
            defer { watchdog.cancel() }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard p.terminationStatus == 0 else {
                let noise = String(decoding: errData, as: UTF8.self)
                    .split(separator: "\n")
                    .filter { !$0.contains("can't change option") && !$0.contains("no job control") }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw ShellError(output: text.isEmpty ? noise : text)
            }
            return text
        }.value
    }
}
