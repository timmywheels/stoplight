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
            if showWatchField {
                Divider()
                WatchField(model: model, isPresented: $showWatchField, focused: $watchFieldFocused)
            }
            Divider()
            footer
        }
        .frame(width: 360)
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
                // MenuBarExtra windows size to the view's ideal height, and a ScrollView has none.
                // Short lists render inline so the window fits them; long lists get a fixed-height ScrollView.
                if rowCount > 9 {
                    ScrollView { list }.frame(height: 480)
                } else {
                    list
                }
            }
        }
    }

    private var rowCount: Int {
        model.sections.reduce(0) { $0 + (model.prefs.collapsedSections.contains($1.id) ? 0 : $1.prs.count) }
    }

    private var list: some View {
        let sections = model.sections
        // With only "Mine" there's nothing to distinguish, so no header at all (looks like v1).
        let showHeaders = !(sections.count == 1 && sections[0].title == "Mine")
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
    private func showSettings() {
        openSettings()
        NSApp.activate()
        DispatchQueue.main.async {
            let win = NSApp.windows.first { $0.identifier?.rawValue.contains("Settings") == true }
                ?? NSApp.windows.first { $0.title == "Settings" || $0.title.hasPrefix("Stoplight") && $0.isVisible }
            win?.makeKeyAndOrderFront(nil)
        }
    }

    private func centered(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
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
    @State private var expanded = false
    @State private var hovering = false
    @State private var copied: String?  // which glyph just copied, for the 1s checkmark
    @State private var editingAlias = false
    @State private var showDescription = false
    @State private var aliasDraft = ""
    @FocusState private var aliasFocused: Bool

    private var pinned: Bool { model.isPinned(pr) }
    private var watched: Bool { model.isWatched(pr) }
    private var isMine: Bool { model.isMine(pr) }
    private var alias: String? { model.prefs.alias(for: pr.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { if !editingAlias { openURL(pr.url) } } label: {
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
                                .help(infoText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(pr.updatedAt.compactAgo).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                    if pr.state == .failure {
                        Button { expanded.toggle() } label: {
                            Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                                .font(.caption).foregroundStyle(.secondary).frame(width: 10)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Hover toolbar floats over the trailing edge instead of reserving width (US-005: titles get the room).
            // Two actions only: open, and copy a pasteable link. Everything else is in the right-click menu.
            .overlay(alignment: .trailing) {
                if hovering && !editingAlias {
                    HStack(spacing: 12) {
                        Button { openURL(pr.url) } label: {
                            Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain).help("Open on GitHub")
                        copyGlyph("doc.on.doc", help: "Copy URL") { copy(pr.url.absoluteString) }
                        copyGlyph("square.and.arrow.up", help: "Share: copies a rich link (hyperlink in Slack, Markdown in GitHub)") { copyRichLink() }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.trailing, 10)
                    .transition(.opacity)
                }
            }
            .onHover { hovering = $0 }
            .contextMenu {
                Button(pinned ? "Unpin" : "Pin") { model.togglePin(pr) }
                Button(showDescription ? "Hide description" : "Show description") { showDescription.toggle() }
                Button(alias == nil ? "Nickname…" : "Edit nickname…") { startEditingAlias() }
                if alias != nil { Button("Clear nickname") { model.prefs.setAlias("", for: pr.id) } }
                if watched {
                    Button("Stop watching") { model.unwatch(pr) }
                }
                Divider()
                if !isMine && !model.prefs.isFollowing(user: pr.author) {
                    Button("Follow @\(pr.author)") { model.follow(user: pr.author) }
                }
                Button("Hide \(pr.repo)") { model.hide(repo: pr.repo) }
                Divider()
                Button("Share (rich link)") { copyRichLink() }
                Button("Copy URL") { copy(pr.url.absoluteString) }
                if !pr.headRefName.isEmpty { Button("Copy branch name") { copy(pr.headRefName) } }
                if let stack, stack.count > 1 {
                    Button("Copy stack (\(stack.count) PRs) as Markdown") { copy(Stacks.markdown(stack)) }
                }
            }

            if showDescription {
                VStack(alignment: .leading, spacing: 4) {
                    if alias != nil { Text(pr.title).font(.caption.weight(.medium)) }
                    Text(pr.summary.isEmpty ? "No description." : pr.summary)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .padding(.leading, 34).padding(.trailing, 12).padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if expanded {
                ForEach(pr.failingChecks) { check in
                    Button { if let u = check.url { openURL(u) } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
                            Text(check.name).font(.caption).lineLimit(1)
                            Spacer()
                        }
                        .padding(.leading, 34).padding(.trailing, 12).padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 6)
            }
        }
    }

    /// Tooltip: real title when nicknamed, then the description.
    private var infoText: String {
        var parts: [String] = []
        if alias != nil { parts.append(pr.title) }
        if !pr.summary.isEmpty { parts.append(pr.summary) }
        return parts.isEmpty ? pr.title : parts.joined(separator: "\n\n")
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

    /// Toolbar glyph that runs a copy action and shows a checkmark for a second.
    private func copyGlyph(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            copied = symbol
            Task { try? await Task.sleep(for: .seconds(1)); if copied == symbol { copied = nil } }
        } label: {
            Image(systemName: copied == symbol ? "checkmark" : symbol)
                .font(.caption).foregroundStyle(copied == symbol ? .green : .secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// One clipboard entry, two flavors: HTML (Slack, Notion, Docs paste a real hyperlink) and
    /// Markdown as the plain-text fallback (GitHub, Linear, terminals).
    private func copyRichLink() {
        let label = "\(pr.repo)#\(pr.number) \(pr.title)"
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
