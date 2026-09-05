import AppKit
import Carbon.HIToolbox
import StoplightCore

/// Every shortcut in one table (US-026). The panel's key handler and the "Keyboard Shortcuts" sheet both read it.
enum Hotkey: CaseIterable {
    case toggleGlobal
    case moveDown, moveUp, open, expand, collapse, close, nextButton, prevButton
    case copyURL, share, copyBranch, pin, fix, hide, checks
    case filterRed, filterYellow, filterGreen, clearFilters
    case toggleSections, refresh, watch, settings, showHotkeys

    struct Combo { let key: String; let symbol: String; let mods: NSEvent.ModifierFlags }

    var combo: Combo {
        switch self {
        case .toggleGlobal: Combo(key: "s", symbol: "S", mods: [.option, .command])
        case .moveDown: Combo(key: "↓", symbol: "↓", mods: [])
        case .moveUp: Combo(key: "↑", symbol: "↑", mods: [])
        case .open: Combo(key: "↩", symbol: "↩", mods: [])
        case .expand: Combo(key: " ", symbol: "Space", mods: [])
        case .collapse: Combo(key: "←", symbol: "←", mods: [])
        case .close: Combo(key: "⎋", symbol: "Esc", mods: [])
        case .nextButton: Combo(key: "⇥", symbol: "Tab", mods: [])
        case .prevButton: Combo(key: "⇥", symbol: "Tab", mods: [.shift])
        case .copyURL: Combo(key: "c", symbol: "C", mods: [.command])
        case .share: Combo(key: "c", symbol: "C", mods: [.shift, .command])
        case .copyBranch: Combo(key: "b", symbol: "B", mods: [.command])
        case .pin: Combo(key: "p", symbol: "P", mods: [.command])
        case .fix: Combo(key: "f", symbol: "F", mods: [.command])
        case .hide: Combo(key: "h", symbol: "H", mods: [.command])
        case .checks: Combo(key: "k", symbol: "K", mods: [.command])
        case .filterRed: Combo(key: "1", symbol: "1", mods: [.command])
        case .filterYellow: Combo(key: "2", symbol: "2", mods: [.command])
        case .filterGreen: Combo(key: "3", symbol: "3", mods: [.command])
        case .clearFilters: Combo(key: "0", symbol: "0", mods: [.command])
        case .toggleSections: Combo(key: "e", symbol: "E", mods: [.shift, .command])
        case .refresh: Combo(key: "r", symbol: "R", mods: [.command])
        case .watch: Combo(key: "n", symbol: "N", mods: [.command])
        case .settings: Combo(key: ",", symbol: ",", mods: [.command])
        case .showHotkeys: Combo(key: "/", symbol: "/", mods: [.command])
        }
    }

    var title: String {
        switch self {
        case .toggleGlobal: "Show or hide Stoplight (works anywhere)"
        case .moveDown: "Next PR"
        case .moveUp: "Previous PR"
        case .open: "Open selected PR on GitHub"
        case .expand: "Expand or collapse selected PR"
        case .collapse: "Collapse selected PR"
        case .close: "Close the panel"
        case .nextButton: "Next button in the expanded PR (↩ presses it)"
        case .prevButton: "Previous button"
        case .copyURL: "Copy URL"
        case .share: "Share (title as a link)"
        case .copyBranch: "Copy branch name"
        case .pin: "Pin or unpin"
        case .fix: "Fix with your agent"
        case .hide: "Hide this PR"
        case .checks: "Open the full checks summary"
        case .filterRed: "Toggle red filter"
        case .filterYellow: "Toggle yellow filter"
        case .filterGreen: "Toggle green filter"
        case .clearFilters: "Clear filters"
        case .toggleSections: "Collapse or expand all sections"
        case .refresh: "Refresh now"
        case .watch: "Watch a PR by URL"
        case .settings: "Settings"
        case .showHotkeys: "Keyboard shortcuts"
        }
    }

    /// "⌥⌘S", "⇧⌘C", "↓"
    var display: String {
        var s = ""
        if combo.mods.contains(.control) { s += "⌃" }
        if combo.mods.contains(.option) { s += "⌥" }
        if combo.mods.contains(.shift) { s += "⇧" }
        if combo.mods.contains(.command) { s += "⌘" }
        return s + combo.symbol
    }

    static let groups: [(String, [Hotkey])] = [
        ("Anywhere", [.toggleGlobal]),
        ("Navigate", [.moveDown, .moveUp, .expand, .nextButton, .prevButton, .collapse, .close]),
        ("Selected PR", [.open, .checks, .copyURL, .share, .copyBranch, .pin, .fix, .hide]),
        ("Filter", [.filterRed, .filterYellow, .filterGreen, .clearFilters]),
        ("Panel", [.toggleSections, .refresh, .watch, .settings, .showHotkeys]),
    ]

    /// Match a key event. Arrow/return/space/escape by key code; letters by character.
    static func match(_ e: NSEvent) -> Hotkey? {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        for h in allCases where h != .toggleGlobal {
            let c = h.combo
            guard c.mods == mods else { continue }
            switch c.key {
            case "↓": if e.keyCode == 125 { return h }
            case "↑": if e.keyCode == 126 { return h }
            case "←": if e.keyCode == 123 { return h }
            case "↩": if e.keyCode == 36 || e.keyCode == 76 { return h }
            case " ": if e.keyCode == 49 { return h }
            case "⎋": if e.keyCode == 53 { return h }
            case "⇥": if e.keyCode == 48 { return h }
            default: if chars == c.key { return h }
            }
        }
        return nil
    }
}

/// System-wide ⌥⌘S via Carbon. No accessibility permission needed.
/// `@unchecked Sendable`: the only cross-thread hop is the Carbon callback bouncing to the main queue.
final class GlobalHotkey: @unchecked Sendable {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { me.action() } }
            return noErr
        }, 1, &type, selfPtr, &handler)
        let id = EventHotKeyID(signature: OSType(0x5354_4C54), id: 1)  // "STLT"
        RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

/// Clipboard actions shared by the row buttons, the context menu, and the hotkeys.
enum PRActions {
    static func copyURL(_ pr: PullRequest) { copy(pr.url.absoluteString) }
    static func copyBranch(_ pr: PullRequest) { copy(pr.headRefName) }

    static func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    /// HTML for Slack/Notion/Docs (a real hyperlink) plus Markdown as the plain-text fallback. Link text is the title.
    static func share(_ pr: PullRequest) {
        let label = pr.title
        let markdown = "[\(label)](\(pr.url.absoluteString))"
        let escaped = label.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let html = "<a href=\"\(pr.url.absoluteString)\">\(escaped)</a>"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.html, .string], owner: nil)
        pb.setString(html, forType: .html)
        pb.setString(markdown, forType: .string)
    }
}
