import SwiftUI
import StoplightCore

/// Settings → Agent (US-025): which coding agent, which terminal, the prompt, and where your clones live.
struct AgentSettingsTab: View {
    @Bindable var model: AppModel
    @State private var scanning = false
    @State private var repoFilter = ""
    @State private var detected = false

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section {
                Picker(selection: $prefs.agent) {
                    Text("Off").tag("")
                    ForEach(AgentLauncher.Agent.allCases) { a in
                        let installed = model.installedAgents.contains(a)
                        Text(installed || a == .custom ? a.title : "\(a.title) (not found)").tag(a.rawValue)
                            .selectionDisabled(!installed && a != .custom)
                    }
                } label: {
                    InfoLabel("Coding agent", "Who gets the PR. Greyed-out agents aren't on your PATH.")
                }
                if prefs.agent == AgentLauncher.Agent.custom.rawValue {
                    LabeledContent {
                        TextField("", text: $prefs.agentCustomCommand, prompt: Text("myagent {args} {prompt}"))
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                    } label: {
                        InfoLabel("Command", "{prompt} becomes the filled-in template, {args} the extra arguments below.")
                    }
                }
                if let agent = AgentLauncher.Agent(rawValue: prefs.agent), !agent.permissionModes.isEmpty {
                    Picker(selection: $prefs.agentPermissionMode) {
                        ForEach(agent.permissionModes, id: \.id) { Text($0.title).tag($0.id) }
                    } label: {
                        InfoLabel("Permissions when fixing", "How much the agent may do on its own with ⌘F. It edits code, so asking first is safest.")
                    }
                    Picker(selection: $prefs.agentReviewPermissionMode) {
                        ForEach(agent.permissionModes, id: \.id) { Text($0.title).tag($0.id) }
                    } label: {
                        InfoLabel("Permissions when reviewing", "For ⇧⌘F, which only reads and reports. Plan mode keeps it off your files.")
                    }
                }
                LabeledContent {
                    TextField("", text: $prefs.agentExtraArgs, prompt: Text("--model opus"))
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                } label: {
                    InfoLabel("Extra arguments", "Appended to every agent command, like a model choice or a config path.")
                }
                Picker(selection: $prefs.terminal) {
                    ForEach(AgentLauncher.Terminal.allCases) { t in
                        Text(t.isInstalled ? t.title : "\(t.title) (not installed)").tag(t.rawValue)
                            .selectionDisabled(!t.isInstalled)
                    }
                } label: {
                    InfoLabel("Open in", "One window per PR, reused while that session is still running.")
                }
            } header: {
                Text("Agent")
            } footer: {
                Text("Fix and Adversarial review hand a PR to this agent in its own worktree, so your checkout is untouched. Fixing edits code and defaults to asking; reviewing only reports and defaults to plan mode.")
            }

            Section {
                DisclosureGroup {
                    TextEditor(text: $prefs.promptTemplate)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 96)
                        .scrollContentBackground(.hidden)
                    HStack {
                        Spacer()
                        Button("Reset") { prefs.promptTemplate = AgentLauncher.defaultPrompt }.controlSize(.small)
                    }
                } label: {
                    InfoLabel("Fix prompt", "Sent with ⌘F. Placeholders below are filled in from that PR.")
                }
                DisclosureGroup {
                    TextEditor(text: $prefs.reviewTemplate)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 96)
                        .scrollContentBackground(.hidden)
                    HStack {
                        Spacer()
                        Button("Reset") { prefs.reviewTemplate = AgentLauncher.defaultReviewPrompt }.controlSize(.small)
                    }
                } label: {
                    InfoLabel("Review prompt", "Sent with ⇧⌘F: pick the PR apart and report, don't fix it.")
                }
            } header: {
                Text("Prompts")
            } footer: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Both prompts take the same placeholders, filled in from the PR:")
                    Text(verbatim: "{number}  {title}  {repo}  {branch}  {base}  {sha}  {url}")
                        .monospaced().textSelection(.enabled)
                    Text(verbatim: "{failing_checks}  {check_urls}  {description}")
                        .monospaced().textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        TextField("", text: tildePath, prompt: Text("~/dev"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .onSubmit(scan)
                        Button("Choose…") { chooseRoot() }
                        Button(scanning ? "Scanning…" : "Scan") { scan() }.disabled(scanning)
                    }
                } label: {
                    InfoLabel("Folder to scan", "Where your git clones live. Stoplight matches each clone's remote to a repo.")
                }
                if model.prefs.repoPaths.isEmpty {
                    Text("No clones found yet. Scan a folder that holds your git checkouts; remotes are matched to the PRs' repos.")
                        .foregroundStyle(.secondary).font(.callout)
                } else {
                    // A dev folder holds hundreds of clones. They cost nothing to keep (it's a lookup
                    // table, consulted only when a PR goes to the agent), so the list folds away instead.
                    DisclosureGroup {
                        TextField("", text: $repoFilter, prompt: Text("Filter"))
                            .textFieldStyle(.roundedBorder).labelsHidden()
                        // A List here inherits the Form's own scroll view and never scrolls itself,
                        // so this is a plain ScrollView with the bordered look drawn by hand.
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(matchingRepos.enumerated()), id: \.element.key) { i, item in
                                    HStack(spacing: 8) {
                                        Text(item.key).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 12)
                                        Text(item.value.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        Button { prefs.repoPaths[item.key] = nil } label: { Image(systemName: "minus.circle") }
                                            .buttonStyle(.borderless).help("Forget this clone")
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(i.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.04))
                                }
                            }
                        }
                        .frame(height: 6 * 24 + 2)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                        HStack {
                            Spacer()
                            Button("Forget All") { prefs.repoPaths = [:]; repoFilter = "" }.controlSize(.small)
                        }
                    } label: {
                        InfoLabel("\(model.prefs.repoPaths.count) clones mapped",
                                  "Only consulted when a PR goes to the agent, so extras are harmless.")
                    }
                }
            } header: {
                Text("Repos")
            } footer: {
                Text("A repo needs a clone here before its PRs can go to the agent. Scanning is one pass over the folder, two levels deep; worktrees are created beside each clone as repo-branch.")
            }
        }
        .formStyle(.grouped)
        .task { if !detected { await model.detectAgents(); detected = true } }
    }

    private var matchingRepos: [(key: String, value: String)] {
        let all = model.prefs.repoPaths.sorted { $0.key < $1.key }
        let q = repoFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.key.contains(q) || $0.value.lowercased().contains(q) }
    }

    /// Shown with a ~, stored absolute.
    private var tildePath: Binding<String> {
        Binding(get: { (model.prefs.scanRoot as NSString).abbreviatingWithTildeInPath },
                set: { model.prefs.scanRoot = ($0 as NSString).expandingTildeInPath })
    }

    /// Same folder picker the gh path row uses, so both rows behave alike.
    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder that holds your git clones"
        panel.directoryURL = URL(fileURLWithPath: model.prefs.scanRoot)
        if panel.runModal() == .OK, let url = panel.url {
            model.prefs.scanRoot = url.path
            scan()
        }
    }

    private func scan() {
        scanning = true
        Task {
            let found = await AgentLauncher.scanRepos(root: model.prefs.scanRoot)
            model.prefs.repoPaths.merge(found) { _, new in new }
            scanning = false
        }
    }
}
