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
            if model.isEmpty {
                centered("No open PRs")
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
                ForEach(sec.prs) { pr in
                    PRRow(pr: pr, model: model)
                    Divider().padding(.leading, 28)
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
            if let err = model.lastError {
                Label("Stale, retrying", systemImage: "wifi.exclamationmark")
                    .font(.caption).foregroundStyle(.orange).help(err)
            } else if let t = model.lastRefresh {
                Text("Updated \(t, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
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
    @Environment(\.openURL) private var openURL
    @State private var expanded = false
    @State private var hovering = false

    private var pinned: Bool { model.isPinned(pr) }
    private var watched: Bool { model.isWatched(pr) }
    private var isMine: Bool { model.isMine(pr) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { openURL(pr.url) } label: {
                HStack(spacing: 10) {
                    StatusDot(state: pr.state, hollow: pr.isDraft)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(pr.shortRef).font(.caption).foregroundStyle(.secondary)
                            if !isMine {
                                Text("· @\(pr.author)").font(.caption).foregroundStyle(.secondary)
                            }
                            if pr.isDraft { tag("Draft") }
                            if pr.status == .merged { tag("Merged", color: .purple) }
                            if pr.status == .closed { tag("Closed", color: .red) }
                        }
                        Text(pr.title).lineLimit(1).truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 8)
                    // Description tooltip lives on this icon only. Always laid out; visible on hover when there is a body.
                    Image(systemName: "info.circle")
                        .font(.caption).foregroundStyle(.secondary).frame(width: 14)
                        .opacity(hovering && !pr.summary.isEmpty ? 1 : 0)
                        .help(pr.summary)
                    // US-012 hover pin glyph. Always laid out so the row never shifts; invisible until hover or pinned.
                    Button { model.togglePin(pr) } label: {
                        Image(systemName: pinned ? "pin.fill" : "pin")
                            .font(.caption).foregroundStyle(pinned ? .primary : .secondary)
                            .frame(width: 14)
                    }
                    .buttonStyle(.plain)
                    .opacity(hovering || pinned ? 1 : 0)
                    .help(pinned ? "Unpin" : "Pin")
                    Text(pr.updatedAt.compactAgo).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                    Button { expanded.toggle() } label: {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                            .font(.caption).foregroundStyle(.secondary).frame(width: 10)
                    }
                    .buttonStyle(.plain)
                    .opacity(pr.state == .failure ? 1 : 0)
                    .disabled(pr.state != .failure)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .contextMenu {
                Button(pinned ? "Unpin" : "Pin") { model.togglePin(pr) }
                if watched {
                    Button("Stop watching") { model.unwatch(pr) }
                }
                Divider()
                if !isMine && !model.prefs.isFollowing(user: pr.author) {
                    Button("Follow @\(pr.author)") { model.follow(user: pr.author) }
                }
                Button("Hide \(pr.repo)") { model.hide(repo: pr.repo) }
                Button("Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pr.url.absoluteString, forType: .string)
                }
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

    private func tag(_ text: String, color: Color = .secondary) -> some View {
        Text(text).font(.caption2).foregroundStyle(color)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
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
