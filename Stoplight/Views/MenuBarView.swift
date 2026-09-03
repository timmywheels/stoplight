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

    private var rowCount: Int { model.pinnedPRs.count + model.minePRs.count + model.watchingPRs.count }

    private var list: some View {
        VStack(spacing: 0) {
            section("Pinned", model.pinnedPRs, showHeader: true)
            section("Mine", model.minePRs, showHeader: !model.pinnedPRs.isEmpty || !model.watchingPRs.isEmpty)
            section("Watching", model.watchingPRs, showHeader: true)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ prs: [PullRequest], showHeader: Bool) -> some View {
        if !prs.isEmpty {
            if showHeader {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(prs) { pr in
                PRRow(pr: pr, model: model)
                Divider().padding(.leading, 28)
            }
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
            Menu {
                Button("Settings…") { openSettings() }.keyboardShortcut(",")
                Divider()
                Button("Quit Stoplight") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings and Quit")
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

struct PRRow: View {
    let pr: PullRequest
    @Bindable var model: AppModel
    @Environment(\.openURL) private var openURL
    @State private var expanded = false
    @State private var hovering = false

    private var pinned: Bool { model.isPinned(pr) }
    private var watched: Bool { model.isWatched(pr) }
    private var isMine: Bool { model.login == pr.author }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { openURL(pr.url) } label: {
                HStack(spacing: 10) {
                    StatusDot(state: pr.state, hollow: pr.isDraft)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(pr.shortRef).font(.caption).foregroundStyle(.secondary)
                            if watched && !isMine {
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
                    // US-012 hover pin glyph. Stays visible when pinned.
                    if hovering || pinned {
                        Button { model.togglePin(pr) } label: {
                            Image(systemName: pinned ? "pin.fill" : "pin")
                                .font(.caption).foregroundStyle(pinned ? .primary : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(pinned ? "Unpin" : "Pin")
                    }
                    Text(pr.updatedAt.compactAgo).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                    if pr.state == .failure {
                        Button { expanded.toggle() } label: {
                            Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
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
