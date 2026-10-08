import Foundation

/// GitHub-style search over the rows (US-032). Bare words match title/nickname; `author:` `repo:` `branch:` `is:` `#n` narrow.
/// All terms AND together. Values match by case-insensitive substring.
public struct SearchQuery: Equatable, Sendable {
    public var words: [String] = []
    public var authors: [String] = []
    public var repos: [String] = []
    public var branches: [String] = []
    public var flags: [String] = []
    public var numbers: [Int] = []
    /// A pasted PR link (or owner/repo#123): the PR it names, which may not be in any list.
    public var pullRequest: PRRef?

    public static let prefixes = ["author:", "repo:", "branch:", "is:"]
    public static let flagValues = ["red", "yellow", "green", "draft", "merged", "queued", "mine", "branch"]

    public init(_ text: String) {
        for raw in text.split(whereSeparator: \.isWhitespace) {
            let t = String(raw).lowercased()
            // A link someone sent you: narrow to that repo and number.
            if let ref = URL(string: String(raw)).flatMap(PRRef.init(url:)) ?? (t.contains("/") ? PRRef(key: String(raw)) : nil) {
                pullRequest = pullRequest ?? ref
                repos.append(ref.repo.lowercased()); numbers.append(ref.number)
            }
            else if t.hasPrefix("author:") { let v = String(t.dropFirst(7)).trimmingCharacters(in: CharacterSet(charactersIn: "@")); if !v.isEmpty { authors.append(v) } }
            else if t.hasPrefix("repo:") { let v = String(t.dropFirst(5)); if !v.isEmpty { repos.append(v) } }
            else if t.hasPrefix("branch:") { let v = String(t.dropFirst(7)); if !v.isEmpty { branches.append(v) } }
            else if t.hasPrefix("is:") { let v = String(t.dropFirst(3)); if !v.isEmpty { flags.append(v) } }
            else if t.hasPrefix("#"), let n = Int(t.dropFirst()) { numbers.append(n) }
            else if let n = Int(t) { numbers.append(n) }
            else { words.append(t) }
        }
    }

    public var isEmpty: Bool { words.isEmpty && authors.isEmpty && repos.isEmpty && branches.isEmpty && flags.isEmpty && numbers.isEmpty }

    /// What the app knows that the PR record doesn't: display names, labels, nicknames, who "mine" is.
    public struct Context: Sendable {
        public var names: @Sendable (String) -> [String]
        public var nickname: @Sendable (String) -> String?
        public var myLogin: String?
        public init(names: @escaping @Sendable (String) -> [String] = { _ in [] },
                    nickname: @escaping @Sendable (String) -> String? = { _ in nil }, myLogin: String? = nil) {
            self.names = names; self.nickname = nickname; self.myLogin = myLogin
        }
    }

    public func matches(_ pr: PullRequest, _ ctx: Context) -> Bool {
        if isEmpty { return true }
        let title = (pr.title + " " + (ctx.nickname(pr.id) ?? "")).lowercased()
        for w in words where !title.contains(w) && !pr.repo.lowercased().contains(w) && !pr.headRefName.lowercased().contains(w) { return false }
        if !numbers.isEmpty && !numbers.contains(pr.number) { return false }
        let authorHay = ([pr.author] + ctx.names(pr.author)).joined(separator: " ").lowercased()
        for a in authors where !authorHay.contains(a) { return false }
        for r in repos where !pr.repo.lowercased().contains(r) { return false }
        for b in branches where !pr.headRefName.lowercased().contains(b) { return false }
        for f in flags {
            let ok: Bool = switch f {
            case "red", "failed", "failing", "failure": pr.state == .failure
            case "yellow", "running", "pending": pr.state == .pending
            case "green", "passed", "passing", "success": pr.state == .success
            case "draft": pr.isDraft
            case "merged": pr.status == .merged
            case "open": pr.status == .open && !pr.isBranch
            case "queued", "queue": pr.mergeQueue != nil
            case "mine", "me": ctx.myLogin.map { $0.caseInsensitiveCompare(pr.author) == .orderedSame } ?? false
            case "branch": pr.isBranch
            default: true   // unknown flag: don't hide everything, just ignore it
            }
            if !ok { return false }
        }
        return true
    }

    // MARK: Completion

    public struct Suggestion: Identifiable, Equatable, Sendable {
        public let label: String     // what the chip shows
        public let insert: String    // what replaces the last token
        public var id: String { insert }
        public init(label: String, insert: String) { self.label = label; self.insert = insert }
    }

    /// Chips for the current text. Empty text or a bare word → the prefixes; `author:d` → matching people; etc.
    public static func suggestions(for text: String, prs: [PullRequest], _ ctx: Context) -> [Suggestion] {
        let last = text.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let lower = last.lowercased()
        func pick(_ prefix: String, _ values: [String]) -> [Suggestion] {
            let partial = String(lower.dropFirst(prefix.count))
            let uniq = Array(NSOrderedSet(array: values.filter { !$0.isEmpty })) as? [String] ?? []
            return uniq.filter { partial.isEmpty || $0.lowercased().contains(partial) }.prefix(8)
                .map { Suggestion(label: $0, insert: prefix + ($0.contains(" ") ? $0.split(separator: " ").first.map(String.init) ?? $0 : $0)) }
        }
        if lower.hasPrefix("author:") {
            var people: [String] = []
            for pr in prs where !pr.author.isEmpty {
                let names = ctx.names(pr.author)
                people.append(names.first.map { "\(pr.author) \($0)" } ?? pr.author)
            }
            return pick("author:", people).map { Suggestion(label: $0.label, insert: "author:" + ($0.label.split(separator: " ").first.map(String.init) ?? $0.label)) }
        }
        if lower.hasPrefix("repo:") { return pick("repo:", prs.map { $0.repo.split(separator: "/").last.map(String.init) ?? $0.repo }) }
        if lower.hasPrefix("branch:") { return pick("branch:", prs.map(\.headRefName)) }
        if lower.hasPrefix("is:") { return pick("is:", flagValues) }
        // Nothing typed, or a plain word: offer the prefixes.
        return prefixes.map { Suggestion(label: $0, insert: $0) }
    }

    /// Replace the last whitespace-separated token with `insert`.
    public static func complete(_ text: String, with insert: String) -> String {
        var parts = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if parts.isEmpty { parts = [""] }
        parts[parts.count - 1] = insert
        let joined = parts.joined(separator: " ")
        return insert.hasSuffix(":") ? joined : joined + " "
    }
}
