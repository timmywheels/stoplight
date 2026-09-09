import AppKit
import Foundation
import OSLog
import StoplightCore

private let log = Logger(subsystem: "com.timwheeler.stoplight", category: "Agent")

/// One button: worktree for the PR's branch, terminal in it, your coding agent running with the failure as its prompt (US-025).
@MainActor
enum AgentLauncher {
    enum Agent: String, CaseIterable, Identifiable {
        case claude, codex, gemini, aider, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "Codex"
            case .gemini: "Gemini CLI"
            case .aider: "Aider"
            case .custom: "Custom command"
            }
        }
        var binary: String? {
            switch self {
            case .claude: "claude"
            case .codex: "codex"
            case .gemini: "gemini"
            case .aider: "aider"
            case .custom: nil
            }
        }
        /// Shell command that starts the agent with a prompt. `prompt` is already shell-quoted.
        /// `args` is passed through verbatim (permission mode, model, anything else).
        func command(prompt: String, custom: String, args: String) -> String {
            let a = args.trimmingCharacters(in: .whitespaces)
            let flags = a.isEmpty ? "" : " " + a
            switch self {
            case .claude: return "claude\(flags) \(prompt)"
            case .codex: return "codex\(flags) \(prompt)"
            case .gemini: return "gemini\(flags) -i \(prompt)"
            case .aider: return "aider\(flags) --message \(prompt)"
            case .custom:
                return custom.replacingOccurrences(of: "{prompt}", with: prompt)
                             .replacingOccurrences(of: "{args}", with: a)
            }
        }

        /// Default permission id per job: fixing asks, reviewing plans (it shouldn't be editing).
        func defaultPermission(for job: Job) -> String {
            guard !permissionModes.isEmpty else { return "ask" }
            return job == .review ? "plan" : "ask"
        }

        /// Permission choices this agent understands. Empty means "no picker, use Extra arguments".
        var permissionModes: [(id: String, title: String, flags: String)] {
            switch self {
            case .claude: [
                ("ask", "Ask every time", ""),
                ("acceptEdits", "Auto-accept file edits", "--permission-mode acceptEdits"),
                ("plan", "Plan only, no changes", "--permission-mode plan"),
                ("bypass", "Bypass all prompts (dangerous)", "--permission-mode bypassPermissions"),
            ]
            default: []
            }
        }
    }

    enum Terminal: String, CaseIterable, Identifiable {
        case terminal, iterm, ghostty, warp
        var id: String { rawValue }
        var title: String {
            switch self {
            case .terminal: "Terminal"
            case .iterm: "iTerm2"
            case .ghostty: "Ghostty"
            case .warp: "Warp"
            }
        }
        var bundleID: String {
            switch self {
            case .terminal: "com.apple.Terminal"
            case .iterm: "com.googlecode.iterm2"
            case .ghostty: "com.mitchellh.ghostty"
            case .warp: "dev.warp.Warp-Stable"
            }
        }
        var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
    }

    static let defaultPrompt = """
    CI failed on PR #{number} "{title}" in {repo} (branch {branch}).
    Failing checks: {failing_checks}
    Logs: {check_urls}
    Find the root cause and fix it on this branch. Run the relevant tests locally before you finish.
    """

    enum Err: LocalizedError {
        case noRepo(String), noAgent, git(String), terminal(String)
        var errorDescription: String? {
            switch self {
            case .noRepo(let r): "No local clone for \(r). Add it in Settings → Agent → Repos."
            case .noAgent: "Pick an agent in Settings → Agent."
            case .git(let m): "git: \(m)"
            case .terminal(let m): "Couldn't open the terminal: \(m)"
            }
        }
    }

    // MARK: Detection

    /// Which agent binaries exist. Deterministic: look for the file in every dir on the login PATH plus the
    /// usual tool folders, instead of trusting an interactive shell to behave in a non-tty.
    static func detectAgents() async -> Set<Agent> {
        let loginPath = (try? await shell("echo $PATH")) ?? ""
        let dirs = (extraPath + ":" + loginPath).split(separator: ":").map(String.init)
        var found = Set<Agent>([.custom])
        for a in Agent.allCases {
            guard let bin = a.binary else { continue }
            if dirs.contains(where: { FileManager.default.isExecutableFile(atPath: "\($0)/\(bin)") }) { found.insert(a) }
        }
        return found
    }

    // MARK: Repos

    /// Scan `root` (two levels deep) for git repos and map "owner/name" → path using their origin remote.
    static func scanRepos(roots: [String]) async -> [String: String] {
        var merged: [String: String] = [:]
        for root in roots where !root.trimmingCharacters(in: .whitespaces).isEmpty {
            // Later roots don't overwrite earlier ones: the first folder listed wins a tie.
            for (slug, path) in await scanRepos(root: root) where merged[slug] == nil { merged[slug] = path }
        }
        return merged
    }

    static func scanRepos(root: String) async -> [String: String] {
        let script = """
        for d in "\(root)"/*/ "\(root)"/*/*/; do
          [ -d "$d/.git" ] || [ -f "$d/.git" ] || continue
          u=$(git -C "$d" remote get-url origin 2>/dev/null) || continue
          echo "$u|${d%/}"
        done
        """
        let out = (try? await shell(script)) ?? ""
        var map: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let slug = repoSlug(fromRemote: parts[0]) else { continue }
            let key = slug.lowercased(), path = parts[1]
            // Several checkouts of one repo (worktrees, experiments): prefer the folder named after the repo, then the shortest path.
            if let existing = map[key] {
                let name = slug.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
                let a = (existing as NSString).lastPathComponent.lowercased() == name
                let b = (path as NSString).lastPathComponent.lowercased() == name
                if a && !b { continue }
                if a == b && existing.count <= path.count { continue }
            }
            map[key] = path
        }
        return map
    }

    /// git@github.com:owner/name.git or https://github.com/owner/name(.git) → "owner/name"
    static func repoSlug(fromRemote url: String) -> String? {
        guard let r = url.range(of: "github.com[:/]([^/]+/[^/\\s]+?)(\\.git)?$", options: .regularExpression) else { return nil }
        var s = String(url[r])
        s = s.replacingOccurrences(of: "github.com:", with: "").replacingOccurrences(of: "github.com/", with: "")
        if s.hasSuffix(".git") { s.removeLast(4) }
        return s
    }

    // MARK: Launch

    struct Config {
        let agent: Agent
        let customCommand: String
        let terminal: Terminal
        let promptTemplate: String
        let reviewTemplate: String
        let repoPaths: [String: String]
        /// Permission flags per job: fixing may edit, reviewing usually shouldn't (US-036).
        let fixFlags: String
        let reviewFlags: String
        /// Anything the user typed; applies to both jobs.
        let extraArgs: String

        func args(for job: Job) -> String {
            [job == .review ? reviewFlags : fixFlags, extraArgs]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }

    /// What the agent is asked to do in the worktree (US-033). (Not `Task`: that shadows Swift concurrency.)
    enum Job: Hashable { case fix, review }

    static let defaultReviewPrompt = """
    Adversarially review PR #{number} "{title}" in {repo} (branch {branch} into {base}).
    Description: {description}
    Assume the author is competent and something is still wrong. Hunt for bugs, unhandled edge cases, race conditions, security issues, missing or weak tests, and misleading names or comments. Run the test suite and any linters.
    Report findings as a numbered list ordered by severity, each with file:line and a one-sentence failure scenario. Do not change code unless I ask.
    """

    /// The branch the agent works on. PRs: the PR's own branch. Branch rows (main is red): a fresh
    /// fix branch off that branch, since nobody should push straight to main.
    static func workBranch(for pr: PullRequest) -> String {
        pr.isBranch ? "fix/\(pr.headRefName.replacingOccurrences(of: "/", with: "-"))-ci-\(pr.headSha.prefix(7))" : pr.headRefName
    }

    /// Create or reuse the worktree. Returns its path.
    static func worktree(for pr: PullRequest, config: Config) async throws -> String {
        guard let clone = config.repoPaths[pr.repo.lowercased()] else { throw Err.noRepo(pr.repo) }
        let branch = workBranch(for: pr)
        let base = pr.headRefName   // for a PR this is the same branch; for a branch row it's the branch to fork from
        let safe = branch.replacingOccurrences(of: "/", with: "-")
        let repoName = (clone as NSString).lastPathComponent
        let path = ((clone as NSString).deletingLastPathComponent as NSString).appendingPathComponent("\(repoName)-\(safe)")
        if FileManager.default.fileExists(atPath: path) { return path }
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        set -e
        cd \(q(clone))
        git fetch origin \(q(base))
        if git show-ref --verify --quiet refs/heads/\(q(branch)); then
          git worktree add \(q(path)) \(q(branch))
        elif git show-ref --verify --quiet refs/remotes/origin/\(q(branch)); then
          git worktree add --track -b \(q(branch)) \(q(path)) origin/\(q(branch))
        else
          git worktree add -b \(q(branch)) \(q(path)) origin/\(q(base))
        fi
        """
        do { _ = try await shell(script) } catch let e as ShellError { throw Err.git(e.output) }
        return path
    }

    /// Branch rows don't have a PR to describe, so they get their own prompt.
    static let branchPrompt = """
    CI failed on {repo} branch {branch} at commit {sha} ("{title}").
    Failing checks: {failing_checks}
    Logs: {check_urls}
    You are on a fresh branch off {branch}. Find the root cause, fix it, run the relevant tests locally, then open a PR against {branch}.
    """

    static func prompt(for pr: PullRequest, template: String) -> String {
        let failing = pr.failingChecks
        let template = pr.isBranch ? branchPrompt : template
        return template
            .replacingOccurrences(of: "{sha}", with: String(pr.headSha.prefix(7)))
            .replacingOccurrences(of: "{base}", with: pr.baseRefName.isEmpty ? "the base branch" : pr.baseRefName)
            .replacingOccurrences(of: "{number}", with: String(pr.number))
            .replacingOccurrences(of: "{title}", with: pr.title)
            .replacingOccurrences(of: "{repo}", with: pr.repo)
            .replacingOccurrences(of: "{branch}", with: pr.headRefName)
            .replacingOccurrences(of: "{url}", with: pr.url.absoluteString)
            .replacingOccurrences(of: "{failing_checks}", with: failing.isEmpty ? "none reported" : failing.map(\.name).joined(separator: ", "))
            .replacingOccurrences(of: "{check_urls}", with: failing.compactMap { $0.url?.absoluteString }.joined(separator: "\n"))
            .replacingOccurrences(of: "{description}", with: pr.summary)
    }

    // MARK: Sessions (US-038)

    /// One live agent terminal per PR. The launcher script writes its own PID and removes it when the
    /// window closes, so "is a session running?" survives Stoplight restarts.
    struct Session: Codable, Sendable {
        let worktree: String
        let terminal: String
        let title: String
        let startedAt: Date
    }

    static var sessionDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".stoplight/sessions")
    }
    /// PR ids contain "/" and "#" for branch rows, so flatten to a filename-safe key.
    static func sessionKey(_ prID: String) -> String {
        String(prID.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }
    static func sessionTitle(_ pr: PullRequest) -> String { "Stoplight · \(pr.shortRef)" }

    /// Liveness is the PID, not the file: a window that dies without running its trap still reads as gone.
    /// Dead files are deleted here so the directory stays clean and PIDs can't be mistaken after reuse.
    private static func isAlive(_ pidFile: URL) -> Bool {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        if kill(pid, 0) == 0 || errno == EPERM { return true }
        try? FileManager.default.removeItem(at: pidFile)
        try? FileManager.default.removeItem(at: pidFile.deletingPathExtension().appendingPathExtension("json"))
        return false
    }

    /// The session for this PR, or nil when there isn't one running.
    static func session(for prID: String) -> Session? {
        let key = sessionKey(prID)
        guard isAlive(sessionDir.appendingPathComponent("\(key).pid")),
              let data = try? Data(contentsOf: sessionDir.appendingPathComponent("\(key).json")),
              let s = try? JSONDecoder().decode(Session.self, from: data) else { return nil }
        return s
    }

    /// Session keys with a live window, for restoring badges after a restart.
    static func liveSessionKeys() -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: nil)) ?? []
        return Set(files.filter { $0.pathExtension == "pid" && isAlive($0) }
                        .map { $0.deletingPathExtension().lastPathComponent })
    }

    /// Bring an existing agent window forward. Terminal and iTerm can raise the exact window by title;
    /// Ghostty and Warp have no scripting API, so those just come to the front.
    static func focus(_ s: Session) async {
        let t = Terminal(rawValue: s.terminal) ?? .terminal
        let title = s.title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        switch t {
        case .terminal:
            await appleScript("""
            tell application "Terminal"
              activate
              repeat with w in windows
                if name of w contains "\(title)" then
                  set index of w to 1
                  return
                end if
              end repeat
            end tell
            """)
        case .iterm:
            await appleScript("""
            tell application "iTerm"
              activate
              repeat with w in windows
                repeat with tb in tabs of w
                  repeat with sn in sessions of tb
                    if name of sn contains "\(title)" then
                      select w
                      select tb
                      return
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            """)
        case .ghostty, .warp:
            _ = try? await shell("open -a \(shq(t.title))")
        }
    }

    /// osascript from a file: no quoting games, and it fails quietly if automation isn't permitted.
    private static func appleScript(_ source: String) async {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("stoplight-\(UUID().uuidString).scpt")
        guard (try? source.write(to: f, atomically: true, encoding: .utf8)) != nil else { return }
        _ = try? await shell("osascript \(shq(f.path))")
        try? FileManager.default.removeItem(at: f)
    }

    /// The URL an agent (or a hook) opens to ping Stoplight about this PR (US-034).
    static func callbackURL(_ state: String, pr: PullRequest) -> String { "stoplight://agent/\(state)/\(pr.id)" }

    /// Claude Code runs shell hooks on events; wire Stop and Notification (permission prompt / waiting for
    /// input) to ping Stoplight. Written per worktree so nothing leaks into the user's real config.
    static func installClaudeHooks(in worktree: String, pr: PullRequest) throws {
        let dir = (worktree as NSString).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = (dir as NSString).appendingPathComponent("settings.local.json")
        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: file),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { root = existing }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        func entry(_ url: String) -> [[String: Any]] {
            [["hooks": [["type": "command", "command": "open \(shq(url))"]]]]
        }
        hooks["Stop"] = entry(callbackURL("done", pr: pr))
        hooks["Notification"] = entry(callbackURL("attention", pr: pr))
        root["hooks"] = hooks
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: URL(fileURLWithPath: file))
        // Keep it out of the user's diff.
        let exclude = (worktree as NSString).appendingPathComponent(".git/info/exclude")
        if FileManager.default.fileExists(atPath: exclude),
           let cur = try? String(contentsOfFile: exclude, encoding: .utf8), !cur.contains(".claude/settings.local.json") {
            try? (cur + "\n.claude/settings.local.json\n").write(toFile: exclude, atomically: true, encoding: .utf8)
        }
    }

    /// Worktree → terminal → agent. `runAgent == false` just opens the terminal in the worktree.
    /// Returns true when it reused a window instead of opening one.
    @discardableResult
    static func fix(_ pr: PullRequest, config: Config, runAgent: Bool, task: Job = .fix) async throws -> Bool {
        // Idempotent: one terminal per PR. A second click goes to the window that's already open.
        if let existing = session(for: pr.id) {
            await focus(existing)
            log.notice("reused session for \(pr.shortRef, privacy: .public)")
            return true
        }
        let path = try await worktree(for: pr, config: config)
        var command = "cd \(shq(path))"
        if runAgent {
            let template = task == .review ? config.reviewTemplate : config.promptTemplate
            var p = prompt(for: pr, template: template)
            if config.agent == .claude {
                try? installClaudeHooks(in: path, pr: pr)   // best effort; the agent still runs without it
            } else {
                p += "\n\nWhen you need my input, run: open '\(callbackURL("attention", pr: pr))'. When you're done, run: open '\(callbackURL("done", pr: pr))'."
            }
            command += " && " + config.agent.command(prompt: shq(p), custom: config.customCommand, args: config.args(for: task))
        }
        let key = sessionKey(pr.id)
        let title = sessionTitle(pr)
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let meta = Session(worktree: path, terminal: config.terminal.rawValue, title: title, startedAt: .now)
        try? JSONEncoder().encode(meta).write(to: sessionDir.appendingPathComponent("\(key).json"))
        try await openTerminal(config.terminal, command: command, directory: path, title: title, key: key)
        log.notice("launched \(config.agent.rawValue, privacy: .public) (\(String(describing: task), privacy: .public)) in \(path, privacy: .public)")
        return false
    }

    /// Write a small launcher script and hand it to the terminal. Sidesteps per-terminal quoting rules and,
    /// for Terminal/iTerm, the AppleScript automation prompt.
    private static func launcherScript(command: String, directory: String, title: String, key: String) throws -> URL {
        // No spaces anywhere in this path: Ghostty hands --command through `bash -c` unquoted.
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".stoplight/launch")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Keep the folder tidy: anything older than a day goes.
        if let old = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) {
            for f in old where ((try? f.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now) < Date.now.addingTimeInterval(-86_400) {
                try? FileManager.default.removeItem(at: f)
            }
        }
        let file = dir.appendingPathComponent("fix-\(Int(Date.now.timeIntervalSince1970)).command")
        let pidFile = sessionDir.appendingPathComponent("\(key).pid").path
        // The window's own shell owns the pid file, so closing the window ends the session however it exits.
        // Not `exec`: the trap has to survive to clean up.
        let body = """
        #!/bin/zsh
        export PATH="\(extraPath):$PATH"
        cd \(shq(directory))
        printf '\\033]0;%s\\007' \(shq(title))
        mkdir -p \(shq(sessionDir.path))
        echo $$ > \(shq(pidFile))
        trap 'rm -f \(shq(pidFile))' EXIT INT TERM HUP
        clear
        \(command)
        \(shq(loginShell.path)) -l
        """
        try body.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    private static func openTerminal(_ t: Terminal, command: String, directory: String, title: String, key: String) async throws {
        // Only the agent command goes in the script; `cd` is handled there too.
        let agentOnly = command.replacingOccurrences(of: "cd \(shq(directory)) && ", with: "").replacingOccurrences(of: "cd \(shq(directory))", with: "")
        let script = try launcherScript(command: agentOnly, directory: directory, title: title, key: key)
        switch t {
        case .terminal:
            _ = try await shell("open -a Terminal \(shq(script.path))")
        case .iterm:
            _ = try await shell("open -a iTerm \(shq(script.path))")
        case .ghostty:
            _ = try await shell("open -na Ghostty --args --working-directory=\(shq(directory)) --command=\(shq(script.path))")
        case .warp:
            // Warp has no scriptable "run this": open the folder and put the command on the clipboard.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(agentOnly, forType: .string)
            _ = try await shell("open -a Warp \(shq(directory))")
        }
    }

    // MARK: Shell helpers

    struct ShellError: Error { let output: String }

    /// Common install dirs that may only be on PATH via .zshrc; prepended so detection and launch see them.
    nonisolated static var extraPath: String {
        let home = NSHomeDirectory()
        var dirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.cargo/bin", "\(home)/.claude/local"]
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: "\(home)/.nvm/versions/node") {
            dirs += versions.sorted().reversed().map { "\(home)/.nvm/versions/node/\($0)/bin" }
        }
        return dirs.joined(separator: ":")
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
            let out = Pipe(); p.standardOutput = out; p.standardError = out
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard p.terminationStatus == 0 else { throw ShellError(output: text) }
            return text
        }.value
    }

    /// Single-quote for POSIX shells.
    static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
