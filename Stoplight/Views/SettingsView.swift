import SwiftUI
import ServiceManagement
import StoplightCore

/// US-008 (General) + US-013 (Sources).
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            DisplayTab(model: model)
                .tabItem { Label("Display", systemImage: "paintpalette") }
            SourcesTab(model: model)
                .tabItem { Label("Sources", systemImage: "person.2") }
            AgentSettingsTab(model: model)
                .tabItem { Label("Agent", systemImage: "cpu") }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 680)
    }
}

private struct GeneralTab: View {
    static let repo = URL(string: "https://github.com/timmywheels/stoplight")!

    @Bindable var model: AppModel
    @AppStorage(Prefs.notifications) private var notifications = "all"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section {
                switch model.auth {
                case .signedIn(let login, let source):
                    LabeledContent("Signed in as", value: "@\(login)")
                    LabeledContent("Source", value: source.rawValue)
                        .help("The GitHub CLI on your PATH, or a token you pasted in.")
                    LabeledContent("Session") {
                        Button("Sign out") { model.signOut() }
                            .help("Clears the stored token and stops fetching.")
                    }
                case .failed(let msg):
                    LabeledContent("Status") {
                        Text(msg).foregroundStyle(prefs.colorProfile.color(for: .failure))
                    }
                default:
                    LabeledContent("Status", value: "Not signed in")
                }
                LabeledContent("GitHub CLI") {
                    HStack(spacing: 8) {
                        Text(TokenSource.ghPath() ?? "Not found")
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(TokenSource.ghPath() == nil ? prefs.colorProfile.color(for: .failure) : .secondary)
                        if !prefs.ghPath.isEmpty { Button("Automatic") { prefs.ghPath = ""; reauth() } }
                        Button("Choose…") { chooseGH() }
                            .help("Point Stoplight at a gh binary somewhere unusual, like a managed Homebrew prefix.")
                    }
                }
                .help("Stoplight reads your GitHub token from this gh install, so it never asks for a password.")
            } header: {
                Text("Account")
            } footer: {
                Text(TokenSource.ghPath() == nil
                     ? "Stoplight couldn't find gh. Choose it, or install the GitHub CLI."
                     : "Found on your shell's PATH. Choose another if gh lives somewhere unusual.")
            }

            Section {
                Picker(selection: $prefs.refreshRate) {
                    ForEach(UserPrefs.RefreshRate.allCases) { Text($0.title).tag($0) }
                } label: {
                    InfoLabel("Check GitHub",
                              "Automatic is 20 seconds while checks run, a minute otherwise. Any choice still speeds up for running checks and backs off near the rate limit.")
                }
            } header: {
                Text("Refreshing")
            } footer: {
                Text("⌘R, the refresh button in the panel, and Refresh Now in the menu bar icon's menu all refresh straight away.")
            }

            Section("Notifications") {
                Picker(selection: $notifications) {
                    Text("When a PR fails or turns all-passing").tag("all")
                    Text("Only when a PR fails").tag("failOnly")
                    Text("Never").tag("off")
                } label: {
                    InfoLabel("Notify me", "Fires when a PR changes state, not on every refresh. A PR that stays red stays quiet.")
                }
                .pickerStyle(.radioGroup)
            }

            Section("Startup") {
                Toggle("Open Stoplight at login", isOn: $launchAtLogin)
                    .help("Registers Stoplight as a macOS login item. It starts hidden, as a menu bar app.")
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section {
                LabeledContent("Version") {
                    HStack(spacing: 8) {
                        Text(model.updater.currentVersion).foregroundStyle(.secondary)
                        updateControl
                    }
                }
                LabeledContent("Guided tour") {
                    Button("Show Again") { model.prefs.tourSeen = false; model.openPanel?() }
                        .help("Replays the first-run walkthrough in the popover.")
                }
                LabeledContent("Source") {
                    Link("github.com/timmywheels/stoplight", destination: Self.repo)
                        .help("Issues and pull requests welcome.")
                }
                LabeledContent("Quit") {
                    Button("Quit Stoplight") { NSApp.terminate(nil) }
                        .keyboardShortcut("q")
                        .help("Stops watching your PRs until you open Stoplight again.")
                }
            } header: {
                Text("About")
            } footer: {
                Text("Made by [@timmywheels](https://github.com/timmywheels). Stoplight is open source.")
            }
        }
        .formStyle(.grouped)
    }
}

/// How Stoplight looks. The bulky parts stay folded until asked for.
private struct DisplayTab: View {
    @Bindable var model: AppModel

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section {
                Picker(selection: $prefs.colorProfile) {
                    ForEach(ColorProfile.allCases) { Text($0.title).tag($0) }
                } label: {
                    InfoLabel("Color profile", "Recolors every dot and badge, menu bar and widget included.")
                }
                .onChange(of: prefs.colorProfile) { _, _ in model.colorProfileChanged() }
            } header: {
                Text("Colors")
            } footer: {
                Text("Deuteranopia swaps green for blue, which stays distinct from red and amber.")
            }

            Section("Menu bar") {
                Toggle(isOn: $prefs.housing) {
                    InfoLabel("Dark housing behind the dots",
                              "Draws a rounded dark plate behind the three dots so they read against a light wallpaper.")
                }
                Toggle(isOn: $prefs.showCount) {
                    InfoLabel("Show a count beside the dots",
                              "How many PRs are red or yellow right now. Same PRs the dots cover, drafts excluded, hidden at zero.")
                }
            }

            Section {
                Picker(selection: $prefs.primaryClick) {
                    ForEach(UserPrefs.PrimaryClick.allCases) { Text($0.title).tag($0) }
                } label: {
                    InfoLabel("Clicking a PR",
                              "The other action moves to double-click, and ⌘-click always does it too.")
                }
                Picker(selection: $prefs.stackOrder) {
                    ForEach(UserPrefs.StackOrder.allCases) { Text($0.title).tag($0) }
                } label: {
                    InfoLabel("Copy a stack starting from",
                              "Right-click a stacked PR → Copy stack as Markdown. Bottom of the stack is the PR merging into trunk.")
                }
                Picker(selection: $prefs.sectionCounts) {
                    Text("Off").tag(UserPrefs.SectionCounts.off)
                    Text("Only what needs attention").tag(UserPrefs.SectionCounts.attention)
                    Text("Every state").tag(UserPrefs.SectionCounts.full)
                } label: {
                    InfoLabel("Counts on collapsed sections",
                              "A collapsed header's summary of the PRs folded inside it. Attention is red and yellow only; Every state adds green and gray.")
                }
                DisclosureGroup {
                    RowActionsEditor(prefs: prefs)
                    Text("The circles in an expanded PR. Check to show, drag to reorder.")
                        .font(.caption).foregroundStyle(.secondary)
                } label: {
                    InfoLabel("Row buttons",
                              "The buttons on an expanded PR: open, copy, share, pin, hand it to the agent.")
                }
            } header: {
                Text("Popover")
            } footer: {
                Text("The footer always tallies every section, which is what lights the menu bar.")
            }

            Section {
                DisclosureGroup {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 7) {
                        legendRow("Red", "At least one check failed.") { StatusDot(state: .failure) }
                        legendRow("Yellow", "Checks still running.") { StatusDot(state: .pending) }
                        legendRow("Green", "Every check passed.") { StatusDot(state: .success) }
                        legendRow("Gray", "Nothing ran: no checks, or all of them skipped.") { StatusDot(state: .none) }
                        legendRow("Hollow", "Draft. Never lights the menu bar or notifies.") {
                            StatusDot(state: .success, hollow: true)
                        }
                        legendRow("Conflicts", "Can't merge until conflicts are fixed. Counts as red.") {
                            Image(systemName: "exclamationmark.triangle.fill").font(.caption)
                                .foregroundStyle(prefs.colorProfile.color(for: .failure))
                        }
                        legendRow("Merged", "The branch badge shows how that branch is doing now.") {
                            Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.githubMerged)
                        }
                        legendRow("Queued", "In the merge queue at that position.") {
                            Image(systemName: "line.3.horizontal").font(.caption).foregroundStyle(.secondary)
                        }
                        legendRow("Stacked", "Targets the PR above it, not the default branch.") {
                            Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        legendRow("Agent", "An agent you launched is waiting on you.") {
                            Image(systemName: "cpu").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                } label: {
                    Text("Legend")
                        .help("What every dot and badge in the popover means.")
                }
            } footer: {
                Text("Right-click a PR for everything else, ⌘/ for every shortcut.")
            }
        }
        .formStyle(.grouped)
    }

    /// One legend line: glyph, short name, meaning. Columns align across every row.
    @ViewBuilder
    private func legendRow<Icon: View>(_ name: String, _ meaning: String,
                                       @ViewBuilder icon: () -> Icon) -> some View {
        GridRow {
            icon().gridColumnAlignment(.center)
            Text(name).gridColumnAlignment(.leading)
            Text(meaning).foregroundStyle(.secondary).gridColumnAlignment(.leading)
        }
        .font(.callout)
    }
}

private extension GeneralTab {
    func reauth() { Task { await model.signIn(); await model.refresh() } }

    /// Pick the gh binary. Unsandboxed, so /opt and /usr/local are reachable.
    func chooseGH() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the gh executable"
        panel.directoryURL = URL(fileURLWithPath: (TokenSource.ghPath() as NSString?)?.deletingLastPathComponent ?? "/opt")
        if panel.runModal() == .OK, let url = panel.url {
            model.prefs.ghPath = url.path
            reauth()
        }
    }

    @ViewBuilder
    var updateControl: some View {
        let u = model.updater
        switch u.state {
        case .checking:
            ProgressView().controlSize(.small)
        case .downloading, .installing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Updating…").foregroundStyle(.secondary) }
        case .available:
            Button("Update to \(u.latest?.version ?? "")") { Task { await u.install() } }.buttonStyle(.borderedProminent)
        case .upToDate:
            Text("Up to date").foregroundStyle(.secondary)
            Button("Check Again") { Task { await u.check() } }
        case .failed(let msg):
            Text(msg).foregroundStyle(.red).font(.caption)
            Button("Retry") { Task { await u.check() } }
        case .idle:
            Button("Check for Updates") { Task { await u.check() } }
        }
    }
}

/// Check to include, drag to reorder (US-031). Unchecked actions sit at the bottom in their canonical order.
private struct RowActionsEditor: View {
    @Bindable var prefs: UserPrefs

    private var rows: [RowAction] {
        prefs.rowActions + RowAction.allCases.filter { !prefs.rowActions.contains($0) }
    }

    var body: some View {
        List {
            ForEach(rows) { a in
                let on = prefs.rowActions.contains(a)
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(get: { on }, set: { set(a, enabled: $0) })) { EmptyView() }.labelsHidden()
                    Image(systemName: a.symbol).frame(width: 18).foregroundStyle(on ? .primary : .secondary)
                    Text(a.title).foregroundStyle(on ? .primary : .secondary)
                    Spacer()
                    if on { Image(systemName: "line.3.horizontal").foregroundStyle(.quaternary) }
                }
                .moveDisabled(!on)
            }
            .onMove { from, to in
                var enabled = prefs.rowActions
                enabled.move(fromOffsets: from, toOffset: min(to, enabled.count))
                prefs.rowActions = enabled
            }
        }
        .listStyle(.bordered)
        .alternatingRowBackgrounds()
        .frame(height: CGFloat(RowAction.allCases.count) * 24 + 2)
    }

    private func set(_ a: RowAction, enabled: Bool) {
        var list = prefs.rowActions
        list.removeAll { $0 == a }
        if enabled { list.append(a) }
        prefs.rowActions = list
    }
}
