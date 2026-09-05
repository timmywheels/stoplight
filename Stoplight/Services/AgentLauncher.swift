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
        /// Shell command that starts the agent with a prompt. `{prompt}` is already shell-quoted.
        func command(prompt: String, custom: String) -> String {
            switch self {
            case .claude: "claude \(prompt)"
            case .codex: "codex \(prompt)"
            case .gemini: "gemini -i \(prompt)"
            case .aider: "aider --message \(prompt)"
            case .custom: custom.replacingOccurrences(of: "{prompt}", with: prompt)
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

    /// Which agent binaries a login shell can see. Cached per launch.
    private(set) static var installedAgents: Set<Agent> = []
    static func detectAgents() async {
        let names = Agent.allCases.compactMap(\.binary).joined(separator: " ")
        // `; true` so a missing last binary doesn't make the whole script exit non-zero.
        let out = (try? await shell("for b in \(names); do command -v $b >/dev/null 2>&1 && echo $b; done; true")) ?? ""
        let found = Set(out.split(separator: "\n").map(String.init))
        installedAgents = Set(Agent.allCases.filter { $0 == .custom || found.contains($0.binary ?? "") })
    }

    // MARK: Repos

    /// Scan `root` (two levels deep) for git repos and map "owner/name" → path using their origin remote.
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
        let repoPaths: [String: String]
    }

    /// Create or reuse the worktree. Returns its path.
    static func worktree(for pr: PullRequest, config: Config) async throws -> String {
        guard let clone = config.repoPaths[pr.repo.lowercased()] else { throw Err.noRepo(pr.repo) }
        let branch = pr.headRefName
        let safe = branch.replacingOccurrences(of: "/", with: "-")
        let repoName = (clone as NSString).lastPathComponent
        let path = ((clone as NSString).deletingLastPathComponent as NSString).appendingPathComponent("\(repoName)-\(safe)")
        if FileManager.default.fileExists(atPath: path) { return path }
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        set -e
        cd \(q(clone))
        git fetch origin \(q(branch))
        if git show-ref --verify --quiet refs/heads/\(q(branch)); then
          git worktree add \(q(path)) \(q(branch))
        else
          git worktree add --track -b \(q(branch)) \(q(path)) origin/\(q(branch))
        fi
        """
        do { _ = try await shell(script) } catch let e as ShellError { throw Err.git(e.output) }
        return path
    }

    static func prompt(for pr: PullRequest, template: String) -> String {
        let failing = pr.failingChecks
        return template
            .replacingOccurrences(of: "{number}", with: String(pr.number))
            .replacingOccurrences(of: "{title}", with: pr.title)
            .replacingOccurrences(of: "{repo}", with: pr.repo)
            .replacingOccurrences(of: "{branch}", with: pr.headRefName)
            .replacingOccurrences(of: "{url}", with: pr.url.absoluteString)
            .replacingOccurrences(of: "{failing_checks}", with: failing.isEmpty ? "none reported" : failing.map(\.name).joined(separator: ", "))
            .replacingOccurrences(of: "{check_urls}", with: failing.compactMap { $0.url?.absoluteString }.joined(separator: "\n"))
            .replacingOccurrences(of: "{description}", with: pr.summary)
    }

    /// Worktree → terminal → agent. `agent == false` just opens the terminal in the worktree.
    static func fix(_ pr: PullRequest, config: Config, runAgent: Bool) async throws {
        let path = try await worktree(for: pr, config: config)
        var command = "cd \(shq(path))"
        if runAgent {
            let p = prompt(for: pr, template: config.promptTemplate)
            command += " && " + config.agent.command(prompt: shq(p), custom: config.customCommand)
        }
        try await openTerminal(config.terminal, command: command, directory: path)
        log.notice("launched \(config.agent.rawValue, privacy: .public) in \(path, privacy: .public)")
    }

    private static func openTerminal(_ t: Terminal, command: String, directory: String) async throws {
        switch t {
        case .terminal:
            try await appleScript("""
            tell application "Terminal"
              activate
              do script \(asq(command))
            end tell
            """)
        case .iterm:
            try await appleScript("""
            tell application "iTerm"
              activate
              set w to (create window with default profile)
              tell current session of w to write text \(asq(command))
            end tell
            """)
        case .ghostty:
            _ = try await shell("open -na Ghostty --args --working-directory=\(shq(directory)) -e /bin/zsh -lc \(shq(command + "; exec /bin/zsh -l"))")
        case .warp:
            // Warp has no scriptable "run this": open the folder and put the command on the clipboard.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            _ = try await shell("open -a Warp \(shq(directory))")
        }
    }

    // MARK: Shell helpers

    struct ShellError: Error { let output: String }

    /// Runs under a login zsh so the user's PATH (Homebrew, npm globals, ~/.local/bin) applies.
    @discardableResult
    static func shell(_ script: String) async throws -> String {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", script]
            let out = Pipe(); p.standardOutput = out; p.standardError = out
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard p.terminationStatus == 0 else { throw ShellError(output: text) }
            return text
        }.value
    }

    private static func appleScript(_ source: String) async throws {
        do { _ = try await shell("osascript -e \(shq(source))") }
        catch let e as ShellError { throw Err.terminal(e.output) }
    }

    /// Single-quote for POSIX shells.
    static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    /// Double-quote for AppleScript string literals.
    private static func asq(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
