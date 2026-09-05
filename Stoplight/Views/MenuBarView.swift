import SwiftUI
import StoplightCore

/// US-005. 360pt wide, scrolls past 480pt, list + footer, nothing else.
/// Sections (US-010/011/012): Pinned, Mine, Watching. Headers only render when non-empty.
struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var showWatchField = false
    @FocusState private var watchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showWatchField {
                Divider()
                WatchField(model: model, isPresented: $showWatchField, focused: $watchFieldFocused)
            }
            Divider()
            footer
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.auth {
        case .unknown:
            centered("Connecting…")
        case .signedOut:
            SignInView(model: model)
        case .failed(let msg):
            VStack(spacing: 8) {
                Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Button("Retry") { Task { await model.signIn(); await model.refresh() } }
            }
            .padding(24)
        case .signedIn:
            if model.lastRefresh == nil && model.lastError == nil {
                centered("Loading…")
            } else if model.isEmpty {
                centered("No open PRs")
            } else if rowCount == 0 && !model.statusFilter.isEmpty {
                centered("No PRs match the filter")
            } else {
                // The panel has a user-chosen size; the list fills it and scrolls. Headers carry 8pt of their own; 4 more makes 12, matching the sides.
                ScrollView { list.padding(.top, 4) }
            }
        }
    }

    private var rowCount: Int {
        model.sections.reduce(0) { $0 + (model.prefs.collapsedSections.contains($1.id) ? 0 : $1.prs.count) }
    }

    private var list: some View {
        let sections = model.sections
        // With only "My PRs" there's nothing to distinguish, so no header at all (looks like v1).
        let showHeaders = !(sections.count == 1 && sections[0].id == "Mine")
        return VStack(spacing: 0) {
            ForEach(sections) { s in
                section(s, showHeader: showHeaders)
            }
        }
    }

    @ViewBuilder
    private func section(_ sec: AppModel.Section, showHeader: Bool) -> some View {
        if !sec.prs.isEmpty {
            let collapsed = showHeader && model.prefs.collapsedSections.contains(sec.id)
            if showHeader {
                SectionHeader(title: sec.title, prs: sec.prs, collapsed: collapsed) { model.prefs.toggleCollapsed(sec.id) }
            }
            if !collapsed {
                let rows = Stacks.layout(sec.prs)
                ForEach(rows) { row in
                    PRRow(pr: row.pr, model: model, section: sec, depth: row.depth,
                          stack: row.stackID.map { Stacks.members(of: $0, in: rows) })
                    Divider().padding(.leading, 28 + CGFloat(row.depth) * 14)
                }
            }
        }
    }

    /// Menu bar apps aren't the active app, so the Settings window would open behind whatever is frontmost.
    /// Hosted in an AppKit panel, the SwiftUI `openSettings` action may be unavailable; fall back to the AppKit selector.
    private func showSettings() {
        openSettings()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate()
        DispatchQueue.main.async {
            let win = NSApp.windows.first { $0.identifier?.rawValue.contains("Settings") == true }
                ?? NSApp.windows.first { $0.title == "Settings" || $0.title.hasPrefix("Stoplight") && $0.isVisible }
            win?.makeKeyAndOrderFront(nil)
        }
    }

    private func centered(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            // US-018: status filters. Click a dot to show only that state; click again to clear. Multi-select.
            if case .signedIn = model.auth, !model.isEmpty {
                HStack(spacing: 8) {
                    ForEach([CIState.failure, .pending, .success], id: \.self) { state in
                        FilterDot(state: state, count: model.count(state),
                                  active: model.statusFilter.isEmpty || model.statusFilter.contains(state),
                                  selected: model.statusFilter.contains(state)) { model.toggleFilter(state) }
                    }
                }
            }
            if let err = model.lastError {
                Label("Stale, retrying", systemImage: "wifi.exclamationmark")
                    .font(.caption).foregroundStyle(.orange).help(err)
            } else if let t = model.lastRefresh {
                Text("\(t, style: .relative) ago").font(.caption).foregroundStyle(.tertiary)
                    .help("Last refreshed")
            }
            Spacer()
            if model.updater.updateAvailable, let v = model.updater.latest?.version {
                Button {
                    Task { await model.updater.install() }
                } label: {
                    Label(model.updater.state == .downloading || model.updater.state == .installing ? "Updating…" : "Update to \(v)",
                          systemImage: "arrow.down.circle")
                        .font(.caption).labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .disabled(model.updater.state == .downloading || model.updater.state == .installing)
                .help("Download, verify, and relaunch")
            }
            Button {
                showWatchField.toggle()
                if showWatchField { watchFieldFocused = true }
            } label: { Image(systemName: showWatchField ? "minus" : "plus") }
                .keyboardShortcut("n").help("Watch a PR by URL (⌘N)")
                .disabled(model.auth == .signedOut || model.auth == .unknown)
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .keyboardShortcut("r").help("Refresh (⌘R)")
                .disabled(model.isRefreshing)
            Button { showSettings() } label: { Image(systemName: "gearshape") }
                .keyboardShortcut(",").help("Settings (⌘,)")
            // ⌘Q still quits while the popover is open; the visible Quit button lives in Settings.
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q").hidden().frame(width: 0, height: 0)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

/// US-011: paste a PR URL, press Return.
struct WatchField: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    var focused: FocusState<Bool>.Binding
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "eye").foregroundStyle(.secondary)
                TextField("Paste a GitHub PR URL", text: $text)
                    .textFieldStyle(.plain)
                    .focused(focused)
                    .onSubmit(submit)
                    .onExitCommand { isPresented = false }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.leading, 24)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func submit() {
        switch model.watch(urlString: text) {
        case .added:
            text = ""; error = nil; isPresented = false
        case .alreadyWatched:
            error = "Already watching that PR"
        case .invalid:
            error = "Not a PR URL"
        }
    }
}

/// Click to collapse. When collapsed, shows the count and the section's worst-state dot so nothing is lost.
struct SectionHeader: View {
    let title: String
    let prs: [PullRequest]
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .frame(width: 10)
                Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                if collapsed {
                    // One count per state, worst first, zeros omitted. Drafts count under "none".
                    ForEach(CIState.allCases, id: \.self) { state in
                        let n = prs.filter { $0.state == state }.count
                        if n > 0 {
                            HStack(spacing: 3) {
                                StatusDot(state: state)
                                Text("\(n)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .padding(.leading, 4)
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, collapsed ? 8 : 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: collapsed)
    }
}

struct PRRow: View {
    let pr: PullRequest
    @Bindable var model: AppModel
    var section: AppModel.Section? = nil
    /// Stack depth (US-015). 0 = bottom of stack or standalone.
    var depth: Int = 0
    /// All rows of this PR's stack, bottom-up. nil when not stacked.
    var stack: [StackRow]? = nil
    @Environment(\.openURL) private var openURL
    @State private var hovering = false
    @State private var copied: String?  // which button just copied, for the 1s checkmark
    @State private var editingAlias = false
    @State private var aliasDraft = ""
    @FocusState private var aliasFocused: Bool

    private var pinned: Bool { model.isPinned(pr) }
    private var watched: Bool { model.isWatched(pr) }
    private var isMine: Bool { model.isMine(pr) }
    private var alias: String? { model.prefs.alias(for: pr.id) }
    private var expanded: Bool { model.expandedID == pr.id }
    private static let motion = Animation.snappy(duration: 0.2, extraBounce: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                expansion
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
        .background(hovering || expanded ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear))
        .onHover { hovering = $0 }
        .contextMenu { menu }
    }

    // MARK: Header row. Click expands; double-click or ⌘-click opens.

    private var header: some View {
        HStack(spacing: 10) {
            if depth > 0 {
                // Stack connector: this PR is based on the row above.
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.leading, CGFloat(depth - 1) * 14)
            }
            StatusDot(state: pr.state, hollow: pr.isDraft)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(section?.refLabel(for: pr) ?? pr.shortRef)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if !isMine && !(section?.hidesAuthor ?? false) {
                        Text("· @\(pr.author)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if pr.isDraft { tag("Draft") }
                    if pr.status == .merged { tag("Merged", color: .purple) }
                    if pr.status == .closed { tag("Closed", color: .red) }
                    if let q = pr.mergeQueue {
                        tag(q.isBlocked ? "Queue: blocked" : "Queue #\(q.position)", color: q.isBlocked ? .red : .blue)
                    }
                    if depth == 0, stack == nil, pr.hasNonTrunkBase {
                        // Based on a branch we can't see: part of a stack whose bottom isn't in view.
                        tag("on \(pr.baseRefName)")
                    }
                    if pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                }
                if editingAlias {
                    TextField(pr.title, text: $aliasDraft)
                        .textFieldStyle(.plain)
                        .focused($aliasFocused)
                        .onSubmit { model.prefs.setAlias(aliasDraft, for: pr.id); editingAlias = false }
                        .onExitCommand { editingAlias = false }
                        .onChange(of: aliasFocused) { _, f in if !f { editingAlias = false } }
                } else {
                    Text(model.displayTitle(pr)).lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(pr.updatedAt.compactAgo).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        // Open-on-click mode: the quick actions come back as a hover toolbar, since there's no expansion to hold them.
        .overlay(alignment: .trailing) {
            if model.prefs.rowClick == .open && hovering && !expanded && !editingAlias {
                HStack(spacing: 12) {
                    glyph(copied == "url" ? "checkmark" : "doc.on.doc", help: "Copy URL", tint: copied == "url" ? .green : nil) {
                        flash("url") { copy(pr.url.absoluteString) }
                    }
                    glyph(copied == "share" ? "checkmark" : "square.and.arrow.up", help: "Share: title as a link",
                          tint: copied == "share" ? .green : nil) { flash("share") { copyRichLink() } }
                    glyph("chevron.down", help: "Expand") { toggleExpand() }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.trailing, 10)
                .transition(.opacity)
            }
        }
        .gesture(
            // Setting decides which of open / expand is the single click; ⌘-click and double-click do the other.
            TapGesture(count: 2).onEnded { secondary() }
                .exclusively(before: TapGesture().onEnded {
                    guard !editingAlias else { return }
                    if NSEvent.modifierFlags.contains(.command) { secondary() } else { primary() }
                })
        )
    }

    private func toggleExpand() { withAnimation(Self.motion) { model.toggleExpanded(pr.id) } }
    private func primary() { model.prefs.rowClick == .expand ? toggleExpand() : openURL(pr.url) }
    private func secondary() { model.prefs.rowClick == .expand ? openURL(pr.url) : toggleExpand() }

    // MARK: Expansion (US-021)

    private var expansion: some View {
        VStack(alignment: .leading, spacing: 10) {
            if alias != nil {
                Text(pr.title).font(.caption.weight(.medium)).lineLimit(2)
            }
            if !pr.summary.isEmpty {
                Text(pr.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
            if !pr.failingChecks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(pr.failingChecks) { check in
                        Button { if let u = check.url { openURL(u) } } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
                                Text(check.name).font(.caption).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 10) {
                circle("arrow.up.right", help: "Open on GitHub") { openURL(pr.url) }
                circle(copied == "url" ? "checkmark" : "doc.on.doc", help: "Copy URL", tint: copied == "url" ? .green : nil) {
                    flash("url") { copy(pr.url.absoluteString) }
                }
                circle(copied == "share" ? "checkmark" : "square.and.arrow.up",
                       help: "Share: title as a link (Slack hyperlink, Markdown elsewhere)", tint: copied == "share" ? .green : nil) {
                    flash("share") { copyRichLink() }
                }
                circle(pinned ? "pin.fill" : "pin", help: pinned ? "Unpin" : "Pin", tint: pinned ? .primary : nil) {
                    withAnimation(Self.motion) { model.togglePin(pr) }
                }
                Spacer()
            }
        }
        .padding(.leading, 34 + CGFloat(depth) * 14).padding(.trailing, 12).padding(.bottom, 10)
    }

    private func glyph(_ symbol: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.caption.weight(.medium)).foregroundStyle(tint ?? .secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func circle(_ symbol: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint ?? .secondary)
                .frame(width: 32, height: 32)
                .background(.quaternary, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func flash(_ key: String, _ action: () -> Void) {
        action()
        copied = key
        Task { try? await Task.sleep(for: .seconds(1)); if copied == key { copied = nil } }
    }

    // MARK: Context menu: the rarer actions

    @ViewBuilder
    private var menu: some View {
        Button(pinned ? "Unpin" : "Pin") { withAnimation(Self.motion) { model.togglePin(pr) } }
        Button(alias == nil ? "Nickname…" : "Edit nickname…") { startEditingAlias() }
        if alias != nil { Button("Clear nickname") { model.prefs.setAlias("", for: pr.id) } }
        if watched { Button("Stop watching") { model.unwatch(pr) } }
        Divider()
        if !isMine && !model.prefs.isFollowing(user: pr.author) {
            Button("Follow @\(pr.author)") { model.follow(user: pr.author) }
        }
        Button("Hide this PR") { model.hide(pr: pr) }
        if pr.mergeQueue != nil, let q = URL(string: "https://github.com/\(pr.repo)/queue/\(pr.baseRefName)") {
            Button("Open merge queue") { openURL(q) }
        }
        Divider()
        Button("Share (rich link)") { copyRichLink() }
        Button("Copy URL") { copy(pr.url.absoluteString) }
        if !pr.headRefName.isEmpty { Button("Copy branch name") { copy(pr.headRefName) } }
        if let stack, stack.count > 1 {
            Button("Copy stack (\(stack.count) PRs) as Markdown") { copy(Stacks.markdown(stack)) }
        }
    }

    private func startEditingAlias() {
        aliasDraft = alias ?? ""
        editingAlias = true
        DispatchQueue.main.async { aliasFocused = true }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    /// One clipboard entry, two flavors: HTML (Slack, Notion, Docs paste a real hyperlink) and
    /// Markdown as the plain-text fallback (GitHub, Linear, terminals). Link text is just the PR title.
    private func copyRichLink() {
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

    private func tag(_ text: String, color: Color = .secondary) -> some View {
        Text(text).font(.caption2).foregroundStyle(color)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}

/// Footer filter toggle: dot + count. Dimmed when another filter excludes it; underlined when selected.
struct FilterDot: View {
    let state: CIState
    let count: Int
    let active: Bool
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                StatusDot(state: state)
                Text("\(count)").font(.caption).monospacedDigit()
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Capsule())
            .opacity(active ? 1 : 0.4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var helpText: String {
        switch state {
        case .failure: "Failing (click to filter)"
        case .pending: "Running (click to filter)"
        case .success: "Passed (click to filter)"
        case .none: "No checks"
        }
    }
}

struct StatusDot: View {
    let state: CIState
    var hollow = false
    @State private var pulse = false

    var color: Color {
        switch state {
        case .failure: .red
        case .pending: .yellow
        case .success: .green
        case .none: .secondary
        }
    }

    var body: some View {
        Circle()
            .strokeBorder(color, lineWidth: hollow ? 1.5 : 0)
            .background(Circle().fill(hollow ? .clear : color))
            .frame(width: 8, height: 8)
            .opacity(state == .pending && pulse ? 0.4 : 1)
            .animation(state == .pending ? .easeInOut(duration: 1).repeatForever() : .default, value: pulse)
            .onAppear { pulse = state == .pending }
    }
}

struct SignInView: View {
    @Bindable var model: AppModel
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to GitHub").font(.headline)
            if TokenSource.ghPath() == nil {
                Text("Install the GitHub CLI and run:").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Run this in a terminal, then click Retry:").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("gh auth login").font(.system(.body, design: .monospaced))
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("gh auth login", forType: .string)
                }
                Button("Retry") { Task { await model.signIn(); await model.refresh() } }
            }
            Divider()
            Text("Or paste a fine-grained token (stored in Keychain):").font(.caption).foregroundStyle(.secondary)
            HStack {
                SecureField("github_pat_…", text: $token)
                Button("Save") { Task { await model.signIn(pastedToken: token); token = "" } }
                    .disabled(token.isEmpty)
            }
        }
        .padding(16)
    }
}
