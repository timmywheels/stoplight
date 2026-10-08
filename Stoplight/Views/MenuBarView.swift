import SwiftUI
import StoplightCore

/// US-005. 360pt wide, scrolls past 480pt, list + footer, nothing else.
/// Sections (US-010/011/012): Pinned, Mine, Watching. Headers only render when non-empty.
struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @FocusState private var watchFieldFocused: Bool

    /// Tour shows once the panel has something real to point at.
    private var showTour: Bool {
        if case .signedIn = model.auth, !model.prefs.tourSeen, model.lastRefresh != nil { return true }
        return false
    }

    @State private var topHeight: CGFloat = 0
    @State private var midHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    private func report() {
        let h = topHeight + midHeight + footerHeight + 2 /* dividers */
        if abs(model.chromeHeight - h) > 0.5 { model.chromeHeight = h }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Real HStack, not overlays: DragHandle is an AppKit view and would swallow clicks anywhere
            // it covers, so it gets the middle only and the buttons keep their own space.
            HStack(spacing: 4) {
                Button { model.isSearching.toggle(); if !model.isSearching { model.searchText = "" } } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(model.isSearching || !model.searchText.isEmpty ? .primary : .secondary)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Search (⌘F)")

                if model.hasQueues {
                    // The toggle takes the middle; the space either side of it is the handle. The
                    // buttons at each end are the same width, so the toggle sits dead centre.
                    dragArea(grip: false)
                    TabToggle(model: model)
                    dragArea(grip: false)
                } else {
                    dragArea(grip: true)
                }
                Button { model.pinnedPanel.toggle() } label: {
                    Image(systemName: model.pinnedPanel ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(model.pinnedPanel ? .primary : .secondary)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.pinnedPanel ? "Unpin: close on click outside again" : "Pin: stay open above other windows")
            }
            .padding(.horizontal, 6).padding(.top, 9).padding(.bottom, 5) // the panel's rounded corner wants a little air above
                .background(GeometryReader { g in Color.clear.onChange(of: g.size.height, initial: true) { _, h in if abs(topHeight - h) > 0.5 { topHeight = h; report() } } })
            VStack(spacing: 0) {
                if model.isSearching {
                    SearchField(model: model)
                    Divider()
                }
            }
            .background(GeometryReader { g in Color.clear.onChange(of: g.size.height, initial: true) { _, h in if abs(midHeight - h) > 0.5 { midHeight = h; report() } } })
            ZStack {
                content
                if showTour {
                    TourView { withAnimation(.snappy(duration: 0.2, extraBounce: 0)) { model.prefs.tourSeen = true } }
                        .transition(.opacity)
                } else if model.showHotkeys {
                    HotkeysView { withAnimation(.snappy(duration: 0.2, extraBounce: 0)) { model.showHotkeys = false } }
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 0) {
                if model.isWatching {
                    Divider()
                    WatchField(model: model, focused: $watchFieldFocused)
                }
                Divider()
                footer
            }
            .background(GeometryReader { g in Color.clear.onChange(of: g.size.height, initial: true) { _, h in if abs(footerHeight - h) > 0.5 { footerHeight = h; report() } } })
        }
        .onChange(of: model.panelVisible) { _, visible in if !visible { model.isWatching = false; model.isSearching = false; model.searchText = "" } }
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
            } else if model.tab == .queue && model.hasQueues {
                if model.queueSections.isEmpty {
                    centered(model.searchText.isEmpty ? "No merge queues. A branch your PRs merge into shows up here when it has one, or pin one in Settings → Sources." : "No queued PRs match “\(model.searchText)”")
                } else {
                    scrolling(queueList)
                }
            } else if model.isEmpty {
                centered("No open PRs")
            } else if rowCount == 0, let sha = model.searchedCommit {
                commitResults(sha)
            } else if rowCount == 0, let ref = model.searchedPullRequest ?? model.searchedNumber {
                UnlistedPullRequest(ref: ref, model: model)
            } else if rowCount == 0 && (!model.statusFilter.isEmpty || !model.searchText.isEmpty) {
                centered(model.searchText.isEmpty ? "No PRs match the filter" : "No PRs match “\(model.searchText)”")
            } else {
                scrolling(list)
            }
        }
    }

    /// A hash none of your rows has as its head: what GitHub found with it, in your repos.
    @ViewBuilder private func commitResults(_ sha: String) -> some View {
        let short = String(sha.prefix(7))
        let found = model.commitResults
        if !found.isEmpty {
            scrolling(VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text("COMMIT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(short).font(.caption2).monospaced().foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
                ForEach(found) { pr in
                    PRRow(pr: pr, model: model)
                    Divider()
                }
            }
            .transition(.opacity))
        } else if model.commitLoading || model.commitQuery != sha {
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { i in SkeletonRow(index: i); Divider() }
                Text("Looking for \(short) in your repos…").font(.caption).foregroundStyle(.tertiary).padding(.top, 10)
                Spacer()
            }
            .onAppear { model.contentHeight = 160 }
        } else {
            centered("No PR in your repos has commit \(short)")
        }
    }

    /// The panel has a user-chosen size; the list fills it and scrolls.
    private func scrolling(_ inner: some View) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                inner
                    .background(GeometryReader { g in
                        Color.clear.onChange(of: g.size.height, initial: true) { _, h in if abs(model.contentHeight - h) > 0.5 { model.contentHeight = h } }
                    })
            }
            .onChange(of: model.selectedID) { _, id in
                if let id { withAnimation(.snappy(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    /// Empty top-bar space that moves the panel. `grip` draws the little bar that says so.
    private func dragArea(grip: Bool) -> some View {
        Group {
            if grip { Capsule().fill(.quaternary).frame(width: 36, height: 4) } else { Color.clear }
        }
        .frame(maxWidth: .infinity).frame(height: 22) // Color.clear would take all the height it's offered
        .overlay(DragHandle())
        .help("Drag to move")
    }

    private var allSectionsCollapsed: Bool {
        !model.sections.isEmpty && model.sections.allSatisfy { model.prefs.collapsedSections.contains($0.id) }
    }

    private var rowCount: Int {
        model.sections.reduce(0) { $0 + (model.isCollapsed($1.id) ? 0 : $1.prs.count) }
    }

    /// The Queue tab: one section per queue, rows in position order.
    private var queueList: some View {
        VStack(spacing: 0) {
            ForEach(model.queueSections) { s in
                section(s, showHeader: true, stacked: false)
            }
        }
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
    private func section(_ sec: AppModel.Section, showHeader: Bool, stacked: Bool = true) -> some View {
        if !sec.prs.isEmpty || sec.queue != nil {
            let collapsed = showHeader && model.isCollapsed(sec.id)
            if showHeader {
                SectionHeader(id: sec.id, title: sec.title, prs: sec.prs, collapsed: collapsed, mode: model.prefs.sectionCounts,
                              allCollapsed: allSectionsCollapsed,
                              url: sec.url,
                              note: sec.headerNote,
                              queue: sec.queue,
                              queuePinned: sec.queue.map { model.prefs.isQueuePinned($0.spec) } ?? false,
                              toggleQueuePin: { if let q = sec.queue { model.toggleQueuePin(q) } },
                              forgetQueue: { if let q = sec.queue { withAnimation(.snappy(duration: 0.2, extraBounce: 0)) { model.forgetQueue(q) } } },
                              toggle: { model.prefs.toggleCollapsed(sec.id) },
                              toggleAll: { _ = model.handle(.toggleSections) },
                              reorderable: sec.queue == nil && model.sections.count > 1,
                              drop: { moving in
                                  withAnimation(.snappy(duration: 0.2, extraBounce: 0)) {
                                      model.prefs.moveSection(moving, onto: sec.id, currentOrder: model.sectionIDs)
                                  }
                                  model.sourcesChanged()
                              })
            }
            if !collapsed && sec.prs.isEmpty {
                Text("Empty").font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 28).padding(.vertical, 8)
                Divider()
            }
            if !collapsed {
                // Queue sections keep GitHub's order: position is the information. Stacks.layout
                // regroups by state and recency, which would scramble exactly that.
                let rows = stacked ? Stacks.layout(sec.prs) : sec.prs.map { StackRow(pr: $0, depth: 0, stackID: nil) }
                ForEach(rows) { row in
                    PRRow(pr: row.pr, model: model, section: sec, depth: row.depth,
                          stack: row.stackID.map { Stacks.members(of: $0, in: rows) })
                    Divider()
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
        Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { model.contentHeight = 120 }
    }

    private var footer: some View {
        // Narrow panel: drop the timestamp first, then the counts' labels never compress (fixedSize).
        ViewThatFits(in: .horizontal) {
            footerRow(showTime: true)
            footerRow(showTime: false)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.leading, 12).padding(.trailing, 6).padding(.top, 4).padding(.bottom, 4)
    }

    private func footerRow(showTime: Bool) -> some View {
        HStack(spacing: 4) {
            // US-018: status filters. Click a dot to show only that state; click again to clear. Multi-select.
            if case .signedIn = model.auth, !model.isEmpty {
                HStack(spacing: 8) {
                    ForEach([CIState.failure, .pending, .success], id: \.self) { state in
                        FilterDot(state: state, count: model.count(state),
                                  active: model.statusFilter.isEmpty || model.statusFilter.contains(state),
                                  selected: model.statusFilter.contains(state)) { model.toggleFilter(state) }
                    }
                }
                .fixedSize()
            }
            if let err = model.lastError {
                if showTime {
                    Label("Stale, retrying", systemImage: "wifi.exclamationmark")
                        .font(.caption).foregroundStyle(.orange).help(err).lineLimit(1).fixedSize()
                } else {
                    Image(systemName: "wifi.exclamationmark").font(.caption).foregroundStyle(.orange).help(err)
                }
            }
            Spacer(minLength: 8)
            if model.updater.updateAvailable, let v = model.updater.latest?.version {
                Button {
                    Task { await model.updater.install() }
                } label: {
                    let busy = model.updater.state == .downloading || model.updater.state == .installing
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                        if showTime { Text(busy ? "Updating…" : "Update to \(v)") }
                    }
                    .font(.caption).fixedSize()
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .disabled(model.updater.state == .downloading || model.updater.state == .installing)
                .help("Download, verify, and relaunch")
            }
            // ⌘N has no button of its own; it lives in the dots' right-click menu.
            Button("Watch a PR") { model.isWatching = true }
                .keyboardShortcut("n").hidden().frame(width: 0, height: 0)
            if showTime, model.lastError == nil, let t = model.lastRefresh {
                // Ticks on its own; the panel can sit open far longer than a refresh interval.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(t.terseAgo)
                        .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                        .lineLimit(1).fixedSize()
                }
                .help("Last refreshed")
                .padding(.trailing, 2)
            }
            Button { Task { await model.refresh() } } label: {
                // AppKit's own spinner while it works: a rotated SF Symbol wobbles off its centre.
                ZStack {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 22, height: 22)
            }
            .keyboardShortcut("r").disabled(model.isRefreshing).help("Refresh now (⌘R)")
            Button { showSettings() } label: { Image(systemName: "gearshape").frame(width: 22, height: 22) }
                .keyboardShortcut(",").help("Settings (⌘,)")
            // ⌘Q still quits while the popover is open; the visible Quit button lives in Settings.
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q").hidden().frame(width: 0, height: 0)
        }
    }
}

/// US-032: type to filter. Esc clears, then closes the field.
struct SearchField: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A real input: the top bar's magnifier already says "search", so no second one in here.
            HStack(spacing: 6) {
                TextField("Search, or paste a link or hash", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onExitCommand {
                        if model.searchText.isEmpty { model.isSearching = false } else { model.searchText = "" }
                    }
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain).help("Clear")
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(focused ? 0.22 : 0.1), lineWidth: 1))
            .animation(.easeOut(duration: 0.12), value: focused)
            // Completion chips: prefixes when idle, matching values once a prefix is typed. Click to insert.
            let chips = model.searchSuggestions
            if !chips.isEmpty || model.peopleLoading {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if model.peopleLoading {
                            // GitHub is looking people up: say so, don't just sit there.
                            ProgressView().controlSize(.mini).help("Looking on GitHub…")
                        }
                        ForEach(chips) { c in
                            Button { model.searchText = SearchQuery.complete(model.searchText, with: c.insert); focused = true } label: {
                                SearchChip(label: c.label)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        // Focus after the field is in the hierarchy; the footer button would otherwise keep it.
        .onAppear { Task { @MainActor in try? await Task.sleep(for: .milliseconds(60)); focused = true } }
        .onChange(of: model.isSearching) { _, on in if on { Task { @MainActor in try? await Task.sleep(for: .milliseconds(60)); focused = true } } }
    }
}

/// US-011: paste a PR URL, press Return.
struct WatchField: View {
    @Bindable var model: AppModel
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
                    .onExitCommand { model.isWatching = false }
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
            text = ""; error = nil; model.isWatching = false
        case .alreadyWatched:
            error = "Already watching that PR"
        case .invalid:
            error = "Not a PR URL"
        }
    }
}

/// Drag a header onto another to reorder (US-023). Off where there's nothing to reorder.
private struct Reorderable: ViewModifier {
    let id: String
    let enabled: Bool
    let drop: (String) -> Void
    @Binding var targeted: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(id)
                .dropDestination(for: String.self) { items, _ in
                    guard let moving = items.first else { return false }
                    drop(moving)
                    return true
                } isTargeted: { targeted = $0 }
        } else {
            content
        }
    }
}

/// Click to collapse. Drag to reorder (US-023). Collapsed: per-state counts so nothing is lost.
struct SectionHeader: View {
    let id: String
    let title: String
    let prs: [PullRequest]
    let collapsed: Bool
    var mode: UserPrefs.SectionCounts = .off
    var allCollapsed = false
    /// Where this section lives on GitHub, when it lives anywhere.
    var url: URL? = nil
    /// The repo every row shares, said once here instead of on each row.
    var note: String? = nil
    /// Set on a merge queue's header: pin it, or stop showing it.
    var queue: BranchRef? = nil
    var queuePinned = false
    var toggleQueuePin: () -> Void = {}
    var forgetQueue: () -> Void = {}
    let toggle: () -> Void
    var toggleAll: () -> Void = {}
    /// Dragging only means something with more than one section to put in order.
    var reorderable = true
    let drop: (String) -> Void
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(collapsed ? -90 : 0))
                .frame(width: 10)
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if let note {
                Text(note).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            if let queue {
                Text(queue.repo.split(separator: "/").last.map(String.init) ?? queue.repo)
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                if queuePinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.tertiary) }
            }
            if collapsed && mode != .off {
                // Attention: only red and yellow get a dot; everything else folds into a quiet total.
                // Full: one count per state, worst first, zeros omitted.
                let states: [CIState] = mode == .full ? CIState.allCases : [.failure, .pending]
                ForEach(states, id: \.self) { state in
                    let n = prs.filter { $0.isCounted && $0.effectiveState == state }.count
                    if n > 0 {
                        HStack(spacing: 3) {
                            StatusDot(state: state)
                            Text("\(n)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(.leading, 4)
                    }
                }
                if mode == .attention {
                    Text("· \(prs.count)").font(.caption2).foregroundStyle(.tertiary).monospacedDigit().padding(.leading, 2)
                }
            }
            Spacer()
            if let url {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain).help("Open on GitHub")
                .padding(.trailing, 2)
            }
            if reorderable {
                Image(systemName: "line.3.horizontal").font(.caption2).foregroundStyle(.quaternary)
                    .help("Drag to reorder")
            }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, collapsed ? 8 : 2)
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            if targeted { Rectangle().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 8) }
        }
        .onTapGesture(perform: toggle)
        .contextMenu {
            Button(collapsed ? "Expand \(title)" : "Collapse \(title)", action: toggle)
            Divider()
            // No .keyboardShortcut here: the panel's own keyDown already owns ⇧⌘E, and
            // registering it twice risks the two handlers cancelling each other out.
            Button(allCollapsed ? "Expand All Sections (⇧⌘E)" : "Collapse All Sections (⇧⌘E)", action: toggleAll)
            if let queue {
                Divider()
                Button(queuePinned ? "Unpin This Queue" : "Always Show This Queue", action: toggleQueuePin)
                Button("Stop Showing \(queue.spec)", action: forgetQueue)
            }
        }
        .modifier(Reorderable(id: id, enabled: reorderable, drop: drop, targeted: $targeted))
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
    @Environment(\.colorProfile) private var colorProfile
    @State private var hovering = false
    /// The title doesn't fit its line; the expanded row then shows all of it.
    @State private var titleTruncated = false
    @State private var copied: String?  // which button just copied, for the 1s checkmark
    @State private var editingAlias = false
    @State private var aliasDraft = ""
    @FocusState private var aliasFocused: Bool

    private var pinned: Bool { model.isPinned(pr) }
    private var watched: Bool { model.isWatched(pr) }
    private var isMine: Bool { model.isMine(pr) }
    private var alias: String? { model.prefs.alias(for: pr.id) }
    private var expanded: Bool { model.expandedID == pr.id }
    private var isQueueRow: Bool { pr.id.hasPrefix("queue:") }
    private var selected: Bool { model.selectedID == pr.id }
    private static let motion = Animation.snappy(duration: 0.2, extraBounce: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                expansion
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .background(selected || model.picked.contains(pr.id) ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                    : hovering || expanded ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear))
        .id(pr.id)
        .onHover { hovering = $0 }
        .contextMenu { menu }
    }

    // MARK: Header row. Click does whatever Settings → Display says; double-click or ⌘-click does the other.

    /// The small line above the title: where the PR lives, who wrote it, how it's doing. Each part
    /// can be turned off (Settings → Display → On each row); with all of them off the line goes away.
    /// Who wrote it, as a picture, yours included. Branch rows keep the space blank so titles line up.
    private var showsAvatar: Bool {
        guard model.prefs.showsDetail(.author) else { return false }
        return section.map { $0.prs.contains { !$0.isBranch } } ?? !pr.isBranch
    }

    static func middleTruncated(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        let head = (max - 1) / 2, tail = max - 1 - head
        return s.prefix(head) + "…" + s.suffix(tail)
    }
    private var avatarSize: CGFloat { model.prefs.density == .comfortable ? 18 : 16 }

    /// After the title: how the PR is doing, then the pin.
    private var trailingStatus: some View {
        HStack(spacing: 6) {
            if !model.prefs.showsDetail(.status) {
                EmptyView()
            } else if model.prefs.statusGlyphs {
                statusLine
            } else {
                if pr.isDraft { tag("Draft") }
                if pr.status == .merged && section?.id != "Merged" { tag("Merged", symbol: "arrow.triangle.merge", tint: .githubMerged) }
                if pr.status == .merged, let bs = pr.baseState {
                    // Base branch health: red / yellow / green by its latest CI run.
                    tag(pr.baseRefName, symbol: "arrow.triangle.branch", tint: stateColor(bs))
                    .help("\(pr.baseRefName) is \(bs == .failure ? "failing" : bs == .pending ? "running" : "passing") right now")
                }
                if let note = pr.note { tag(note) }
                if pr.id.hasPrefix("queue:"), model.isMine(pr) {
                    tag("yours", symbol: "person.fill")
                        .help("Your PR, also listed in its own section above")
                }
                if pr.status == .closed { tag("Closed", symbol: "xmark", tint: stateColor(.failure)) }
                if pr.status == .open, !pr.isDraft, let label = pr.mergeState.label {
                    tag(label, symbol: pr.mergeState.isBlocking ? "exclamationmark.triangle.fill" : nil,
                        tint: pr.mergeState.isBlocking ? stateColor(.failure) : .secondary)
                }
                // A queued PR is approved by definition, so the seal would say nothing here.
                if pr.status == .open, !pr.isDraft, !isQueueRow, let symbol = pr.review.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(pr.review == .changesRequested ? stateColor(.failure)
                                         : pr.review == .approved ? stateColor(.success) : Color.secondary)
                        .help(pr.review.label)
                }
                if let q = pr.mergeQueue, !isQueueRow {
                    tag("Queue \(q.position)",
                        symbol: q.isBlocked ? "exclamationmark.triangle.fill" : "line.3.horizontal",
                        tint: q.isBlocked ? stateColor(.failure) : .secondary)
                    .help(q.isBlocked ? "Blocked: this one can't merge, and everything behind it waits"
                                      : "Position \(q.position) in the merge queue")
                }
                if depth == 0, stack == nil, pr.hasNonTrunkBase {
                    // Based on a branch we can't see: part of a stack whose bottom isn't in view.
                    tag("on \(pr.baseRefName)")
                        .frame(maxWidth: 150, alignment: .leading) // long stack branches shorten in the middle
                        .help("Stacked on \(pr.baseRefName)")
                }
            }
            if pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
    }
    }

    @ViewBuilder private var titleView: some View {
        if editingAlias {
            TextField(pr.title, text: $aliasDraft)
                .textFieldStyle(.plain)
                .focused($aliasFocused)
                .onSubmit { model.prefs.setAlias(aliasDraft, for: pr.id); editingAlias = false }
                .onExitCommand { editingAlias = false }
                .onChange(of: aliasFocused) { _, f in if !f { editingAlias = false } }
        } else {
            MarqueeText(text: model.displayTitle(pr), active: hovering && !expanded, truncated: $titleTruncated)
                .help(pr.isBranch ? pr.shortRef : "\(model.displayTitle(pr))\n\(pr.shortRef) · @\(pr.author)")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if depth > 0 {
                // Stack connector: this PR is based on the row above.
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.leading, CGFloat(depth - 1) * 14)
            }
            if let q = pr.mergeQueue, isQueueRow {
                // Position is the point of this list, so it reads as a number in the gutter
                // rather than another badge. Red when this entry is what everything else waits on.
                Text("\(q.position)")
                    .font(.caption2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(q.isBlocked ? AnyShapeStyle(stateColor(.failure)) : AnyShapeStyle(.tertiary))
                    .frame(width: 16, alignment: .trailing)
                    .help(q.isBlocked ? "Blocked: everything behind it waits" : "Position \(q.position) in the queue")
            }
            if pr.status == .merged {
                // Landed. The branch badge says how the base branch is doing now.
                Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.githubMerged).frame(width: 8)
            } else {
                StatusDot(state: pr.state, hollow: pr.isDraft)
            }
            // One line, in reading order: dot, who, which, what, how it's doing, when.
            if showsAvatar {
                Group {
                    if pr.isBranch || pr.author.isEmpty { Color.clear } else { Avatar(login: pr.author, size: avatarSize) }
                }
                .frame(width: avatarSize, height: avatarSize)
                .help(model.displayName(for: pr.author).map { "\($0) (@\(pr.author))" } ?? "@\(pr.author)")
            }
            if model.prefs.showsDetail(.ref) {
                // Sized to its text: "#801" never shortens, a long "repo #3" is shortened in the middle here.
                Text(Self.middleTruncated(section?.refLabel(for: pr) ?? "\(pr.repo.split(separator: "/").last.map(String.init) ?? pr.repo) #\(pr.number)", max: 18))
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
            }
            titleView
                .font(model.prefs.density == .comfortable ? .body : .callout)
                .layoutPriority(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Hovering swaps status and age for the quick actions, in the same spot: nothing floats
            // over the title, and the tooltip and expanded row still say what status and age said.
            if showsQuickActions {
                quickActions
            } else {
                trailingStatus.lineLimit(1).fixedSize()
                if model.prefs.showsDetail(.age) {
                    Text((pr.mergedAt ?? pr.updatedAt).compactAgo).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, model.prefs.density.rowPadding)
        .contentShape(Rectangle())
        .gesture(
            // Whichever action isn't on the single click lives on the double click, so both are
            // always reachable. ⌘-click always does the other one too (Settings → Display).
            TapGesture(count: 2).onEnded { model.selectedID = pr.id; secondaryClick() }
                .exclusively(before: TapGesture().onEnded {
                    guard !editingAlias else { return }
                    // ⇧-click picks your own open PRs to close together; ⌘-click keeps doing the other action.
                    if NSEvent.modifierFlags.contains(.shift) { return model.togglePicked(pr) }
                    model.picked = []
                    model.selectedID = pr.id
                    if NSEvent.modifierFlags.contains(.command) { secondaryClick() } else { primaryClick() }
                })
        )
    }

    private var showsQuickActions: Bool { hovering && !expanded && !editingAlias }

    private var quickActions: some View {
        HStack(spacing: 10) {
            glyph("arrow.up.right", help: "Open on GitHub") { openURL(pr.url) }
            glyph(copied == "url" ? "checkmark" : "doc.on.doc", help: "Copy URL", tint: copied == "url" ? stateColor(.success) : nil) {
                flash("url") { copy(pr.url.absoluteString) }
            }
            glyph(copied == "share" ? "checkmark" : "square.and.arrow.up", help: "Share: title as a link",
                  tint: copied == "share" ? stateColor(.success) : nil) { flash("share") { copyRichLink() } }
        }
        .fixedSize()
    }

    /// The row's status as glyphs, most urgent first; hover one for its words.
    @ViewBuilder private var statusLine: some View {
        let status = RowStatus.of(pr, isQueueRow: isQueueRow)
        if !status.parts.isEmpty {
            HStack(spacing: 5) {
                ForEach(status.parts, id: \.symbol) { part in
                    HStack(spacing: 2) {
                        Image(systemName: part.symbol)
                        if let n = part.count { Text("\(n)").monospacedDigit() }
                    }
                    .foregroundStyle(color(part.level))
                    .help(part.help)
                    .accessibilityLabel(part.help)
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .fixedSize()
        }
        if pr.id.hasPrefix("queue:"), model.isMine(pr) {
            Image(systemName: "person.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                .help("Your PR, also listed in its own section above")
        }
    }

    /// Only what needs someone gets a color; the rest stays quiet so the dot keeps meaning CI.
    private func color(_ level: RowStatus.Level) -> Color {
        switch level {
        case .blocking: stateColor(.failure)
        case .good: stateColor(.success)
        case .waiting, .info: .secondary
        }
    }

    private func toggleExpand() { withAnimation(Self.motion) { model.toggleExpanded(pr.id) } }

    private func primaryClick() {
        if model.prefs.primaryClick == .expand { toggleExpand() } else { openURL(pr.url) }
    }

    private func secondaryClick() {
        if model.prefs.primaryClick == .expand { openURL(pr.url) } else { toggleExpand() }
    }

    /// "3 of 16 checks failed" / "2 of 4 checks running" / "12 checks passed" / "1 check passed"
    private var checksSummary: String {
        let n = pr.checks.count
        let failed = pr.failingChecks.count
        let pending = pr.checks.filter { $0.state == .pending }.count
        let noun = n == 1 ? "check" : "checks"
        if failed > 0 { return "\(failed) of \(n) \(noun) failed" }
        if pending > 0 { return "\(pending) of \(n) \(noun) running" }
        return "\(n) \(noun) passed"
    }

    // MARK: Expansion (US-021)

    private var expansion: some View {
        VStack(alignment: .leading, spacing: 10) {
            if alias != nil || titleTruncated {
                // The whole title, since the row cut it off (or shows a nickname instead).
                Text(pr.title).font(.callout.weight(.medium)).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !pr.summary.isEmpty {
                Text(pr.summary).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !pr.checks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(pr.failingChecks) { check in
                        Button { if let u = check.url { openURL(u) } } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(stateColor(.failure)).font(.caption)
                                Text(check.name).font(.caption).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    // Every job, every workflow: GitHub's checks tab for the PR.
                    Button { openURL(pr.checksURL) } label: {
                        HStack(spacing: 4) {
                            Text(checksSummary).font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Open the checks tab on GitHub")
                }
            }
            FlowLayout(spacing: 10, rowSpacing: 8) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { i, b in
                    circle(b.symbol, help: b.help, tint: b.tint, focused: selected && model.focusedButton == i, action: b.action)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { if selected { model.expandedButtonCount = buttons.count } }
            .onChange(of: selected) { _, sel in if sel { model.expandedButtonCount = buttons.count } }
            .onChange(of: model.activateFocused) { _, _ in
                guard selected, let i = model.focusedButton, i < buttons.count else { return }
                buttons[i].action()
            }
        }
        .padding(.leading, 34 + CGFloat(depth) * 14).padding(.trailing, 12).padding(.bottom, 10)
    }

    private func glyph(_ symbol: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.caption.weight(.medium)).foregroundStyle(tint ?? .secondary)
                .frame(width: 16, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private struct RowButton { let symbol: String; let help: String; let tint: Color?; let action: () -> Void }

    /// The expanded row's buttons, in the user's order (Settings → General → Row buttons), skipping ones that don't apply.
    private var buttons: [RowButton] {
        model.prefs.rowActions.filter { $0.isAvailable(for: pr, model: model) }.map { a in
            switch a {
            case .open: RowButton(symbol: a.symbol, help: pr.isBranch ? "Open commit on GitHub" : a.title, tint: nil) { openURL(pr.url) }
            case .run: RowButton(symbol: a.symbol, help: "\(a.title) (⌘K)", tint: nil) { if let u = pr.actionsRunURL { openURL(u) } }
            case .checks: RowButton(symbol: a.symbol, help: a.title, tint: nil) { openURL(pr.checksURL) }
            // A `let` here would break the switch's implicit return, so the position is inline.
            case .queue: RowButton(symbol: a.symbol,
                                   help: "\(a.title)\(pr.mergeQueue.map { " · position \($0.position)" } ?? "")",
                                   tint: nil) { if let u = pr.queueURL { openURL(u) } }
            case .copyURL: RowButton(symbol: copied == a.id ? "checkmark" : a.symbol, help: "\(a.title) (⌘C)", tint: copied == a.id ? stateColor(.success) : nil) {
                flash(a.id) { PRActions.copyURL(pr) }
            }
            case .share: RowButton(symbol: copied == a.id ? "checkmark" : a.symbol, help: "\(a.title) (⇧⌘C)", tint: copied == a.id ? stateColor(.success) : nil) {
                flash(a.id) { PRActions.share(pr) }
            }
            case .copyBranch: RowButton(symbol: copied == a.id ? "checkmark" : a.symbol, help: "\(a.title) (⌘B)", tint: copied == a.id ? stateColor(.success) : nil) {
                flash(a.id) { PRActions.copyBranch(pr) }
            }
            case .copyHash: RowButton(symbol: copied == a.id ? "checkmark" : a.symbol, help: "Copy commit hash \(pr.headSha.prefix(7)) (⇧⌘B)", tint: copied == a.id ? stateColor(.success) : nil) {
                flash(a.id) { PRActions.copyHash(pr) }
            }
            case .pin: RowButton(symbol: pinned ? "pin.fill" : "pin", help: pinned ? "Unpin" : "Pin", tint: pinned ? .primary : nil) {
                withAnimation(Self.motion) { model.togglePin(pr) }
            }
            }
        }
    }

    private func circle(_ symbol: String, help: String, tint: Color? = nil, focused: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint ?? .secondary)
                .frame(width: 32, height: 32)
                .background(.quaternary, in: Circle())
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: focused ? 2 : 0))
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
        if !isMine && !pr.isBranch && !model.prefs.isFollowing(user: pr.author) {
            Button("Follow @\(pr.author)") { model.follow(user: pr.author) }
        }
        if pr.isBranch {
            Button("Stop following \(pr.repo)@\(pr.headRefName)") {
                model.prefs.unfollow("\(pr.repo)@\(pr.headRefName)", kind: .branches); model.sourcesChanged()
            }
        } else {
            Button("Hide this PR") { model.hide(pr: pr) }
        }
        if let run = pr.actionsRunURL { Button("Open Actions run") { openURL(run) } }
        if !pr.checks.isEmpty { Button("Open checks tab") { openURL(pr.checksURL) } }
        if pr.mergeQueue != nil, let q = URL(string: "https://github.com/\(pr.repo)/queue/\(pr.baseRefName)") {
            Button("Open merge queue") { openURL(q) }
        }
        Divider()
        Button("Share (rich link)") { copyRichLink() }
        Button("Copy URL") { copy(pr.url.absoluteString) }
        if !pr.headRefName.isEmpty { Button("Copy branch name") { copy(pr.headRefName) } }
        Button("Copy commit hash (\(pr.headSha.prefix(7)))") { PRActions.copyHash(pr) }
        if let stack, stack.count > 1 {
            Button("Copy stack (\(stack.count) PRs) as Markdown") {
                copy(Stacks.markdown(stack, topFirst: model.prefs.stackOrder == .topFirst))
            }
        }
        let closing = model.closeTargets(for: pr)
        if !closing.isEmpty {
            Divider()
            Button(closing.count == 1 ? "Close Pull Request…" : "Close \(closing.count) Pull Requests…") { model.confirmAndClose(closing) }
        }
    }

    private func startEditingAlias() {
        aliasDraft = alias ?? ""
        editingAlias = true
        DispatchQueue.main.async { aliasFocused = true }
    }

    private func copy(_ value: String) { PRActions.copy(value) }
    private func copyRichLink() { PRActions.share(pr) }

    private func stateColor(_ s: CIState) -> Color {
        colorProfile.color(for: s)
    }

    /// Badge text is always neutral; urgency rides on a small tinted glyph instead. Colored words in a
    /// dense list fight the titles and each other.
    private func tag(_ text: String, symbol: String? = nil, tint: Color = .secondary) -> some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(tint)
            }
            Text(text).foregroundStyle(Color.secondary)
                .lineLimit(1).truncationMode(.middle) // a long branch name shortens; it never wraps into a blob
        }
        .font(.caption2)
        .padding(.horizontal, 5).padding(.vertical, 1.5)
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
                // Nothing in this state: no pulse. Same color as the others, so the three read as a set.
                StatusDot(state: state, pulses: count > 0)
                Text("\(count)").font(.caption).monospacedDigit().fixedSize()
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
        let what: String = switch state {
        case .failure: "failing"
        case .pending: "running"
        case .success: "passed"
        case .none: "no checks"
        }
        return "\(count) open \(count == 1 ? "PR" : "PRs") \(what), drafts included: the rows with this dot. The menu bar lights this color when it's above zero. Click to show only these."
    }
}

struct StatusDot: View {
    let state: CIState
    var hollow = false
    /// Off where "running" is a category, not something happening (a footer tally of zero).
    var pulses = true
    @Environment(\.colorProfile) private var colorProfile
    @State private var pulse = false

    var color: Color {
        colorProfile.color(for: state)
    }
    private var shouldPulse: Bool { pulses && state == .pending }

    var body: some View {
        Circle()
            .strokeBorder(color, lineWidth: hollow ? 1.5 : 0)
            .background(Circle().fill(hollow ? .clear : color))
            .frame(width: 8, height: 8)
            .opacity(pulse ? 0.4 : 1)
            .animation(pulse ? .easeInOut(duration: 1).repeatForever() : .default, value: pulse)
            .onAppear { pulse = shouldPulse }
            .onChange(of: shouldPulse) { _, on in pulse = on }
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

/// A pasted link to a PR that isn't in any of your lists: open it anyway, or keep it in the list.
struct UnlistedPullRequest: View {
    let ref: PRRef
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Text("\(ref.repo) #\(ref.number) isn't in your lists").foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Open on GitHub") {
                    model.searchText = ""
                    if let u = URL(string: "https://github.com/\(ref.repo)/pull/\(ref.number)") { NSWorkspace.shared.open(u) }
                }
                .keyboardShortcut(.defaultAction)
                Button("Watch It") {
                    let link = "https://github.com/\(ref.repo)/pull/\(ref.number)"
                    if model.watch(urlString: link) != .invalid { model.searchText = "" }
                }
                .help("Adds it to Watching, where it stays until it closes")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.contentHeight = 120 }
    }
}

/// A completion under the search field. The system font, not monospace: these are words to tap,
/// and a ":" prefix reads fine in the UI face.
struct SearchChip: View {
    let label: String
    @State private var hovering = false

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(hovering ? .primary : .secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(.primary.opacity(hovering ? 0.12 : 0.06)))
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A row-shaped placeholder while something loads: dot, avatar, number and title as soft bars
/// that breathe. Widths vary by index so a stack of them doesn't look like a barcode.
struct SkeletonRow: View {
    var index = 0
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let widths: [CGFloat] = [0.62, 0.48, 0.7, 0.55, 0.66]
        HStack(spacing: 10) {
            Circle().fill(.quaternary).frame(width: 8, height: 8)
            Circle().fill(.quaternary).frame(width: 16, height: 16)
            Capsule().fill(.quaternary).frame(width: 34, height: 9)
            GeometryReader { g in
                Capsule().fill(.quaternary).frame(width: g.size.width * widths[index % widths.count], height: 9)
                    .frame(maxHeight: .infinity)
            }
            .frame(height: 16)
            Capsule().fill(.quaternary).frame(width: 18, height: 9)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .opacity(dim ? 0.45 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever().delay(Double(index) * 0.12)) { dim = true }
        }
        .accessibilityHidden(true)
    }
}

/// PRs | Queue: a small segmented toggle in the top bar. The selection slides; the queue side
/// carries how many are waiting. ⌃⇥ switches too.
struct TabToggle: View {
    @Bindable var model: AppModel
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var queued: Int { model.queueSections.reduce(0) { $0 + $1.prs.count } }

    var body: some View {
        HStack(spacing: 0) {
            segment("PRs", tab: .prs)
            segment("Queue", tab: .queue, count: queued)
        }
        .padding(2)
        .background(Capsule().fill(.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .fixedSize()
        .animation(reduceMotion ? nil : .snappy(duration: 0.22, extraBounce: 0), value: model.tab)
        .help("Your PRs or the merge queue (⌃⇥)")
    }

    private func segment(_ title: String, tab: AppModel.Tab, count: Int = 0) -> some View {
        let on = model.tab == tab
        // No withAnimation here: it would animate the list swapping in too, and its separators flash
        // white for a frame while they fade. Only the pill slides (see .animation below).
        return Button { model.tab = tab } label: {
            HStack(spacing: 4) {
                Text(title)
                if count > 0 {
                    Text("\(count)").monospacedDigit()
                        .foregroundStyle(on ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                }
            }
            .font(.caption.weight(on ? .semibold : .regular))
            .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background {
                if on {
                    Capsule().fill(.background.opacity(0.9))
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                        .matchedGeometryEffect(id: "selection", in: ns)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
