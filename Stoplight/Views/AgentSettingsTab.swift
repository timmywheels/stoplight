import SwiftUI
import StoplightCore

/// Settings → Agent (US-025): which coding agent, which terminal, the prompt, and where your clones live.
struct AgentSettingsTab: View {
    @Bindable var model: AppModel
    @State private var scanning = false
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
                    InfoLabel("Coding agent", "Which CLI coding agent Stoplight hands a PR to. Greyed-out entries aren't installed on your PATH.")
                }
                if prefs.agent == AgentLauncher.Agent.custom.rawValue {
                    LabeledContent {
                        TextField("", text: $prefs.agentCustomCommand, prompt: Text("myagent {args} {prompt}"))
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                    } label: {
                        InfoLabel("Command", "The exact command to run. {prompt} is replaced by the filled-in template, {args} by the extra arguments below.")
                    }
                }
                if let agent = AgentLauncher.Agent(rawValue: prefs.agent), !agent.permissionModes.isEmpty {
                    Picker(selection: $prefs.agentPermissionMode) {
                        ForEach(agent.permissionModes, id: \.id) { Text($0.title).tag($0.id) }
                    } label: {
                        InfoLabel("Permissions when fixing", "How much the agent may do on its own when you send it a failing PR (⌘F). It edits code, so asking first is the safe default.")
                    }
                    Picker(selection: $prefs.agentReviewPermissionMode) {
                        ForEach(agent.permissionModes, id: \.id) { Text($0.title).tag($0.id) }
                    } label: {
                        InfoLabel("Permissions when reviewing", "Permissions for Adversarial review (⇧⌘F), which only reads and reports. Plan mode keeps it from touching files.")
                    }
                }
                LabeledContent {
                    TextField("", text: $prefs.agentExtraArgs, prompt: Text("--model opus"))
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                } label: {
                    InfoLabel("Extra arguments", "Appended to every agent command, for flags like a model choice or a config path.")
                }
                Picker(selection: $prefs.terminal) {
                    ForEach(AgentLauncher.Terminal.allCases) { t in
                        Text(t.isInstalled ? t.title : "\(t.title) (not installed)").tag(t.rawValue)
                            .selectionDisabled(!t.isInstalled)
                    }
                } label: {
                    InfoLabel("Open in", "The terminal app Stoplight opens the agent in. One window per PR, reused if that session is still running.")
                }
            } header: {
                Text("Agent")
            } footer: {
                Text("Fix and Adversarial review hand a PR to this agent in its own worktree, so your checkout is untouched. Fixing edits code and defaults to asking; reviewing only reports and defaults to plan mode.")
            }

            Section("Prompts") {
                DisclosureGroup {
                    TextEditor(text: $prefs.promptTemplate)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 96)
                        .scrollContentBackground(.hidden)
                    HStack {
                        Text("{number} {title} {repo} {branch} {base} {sha} {url} {failing_checks} {check_urls} {description}")
                            .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        Spacer()
                        Button("Reset") { prefs.promptTemplate = AgentLauncher.defaultPrompt }.controlSize(.small)
                    }
                } label: {
                    InfoLabel("Fix prompt", "What Stoplight says to the agent when you send it a failing PR (⌘F). The placeholders below are filled in from that PR.")
                }
                DisclosureGroup {
                    TextEditor(text: $prefs.reviewTemplate)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 96)
                        .scrollContentBackground(.hidden)
                    HStack {
                        Text("Same placeholders. Used by Adversarial review (⇧⌘F).")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset") { prefs.reviewTemplate = AgentLauncher.defaultReviewPrompt }.controlSize(.small)
                    }
                } label: {
                    InfoLabel("Review prompt", "What Stoplight says to the agent for Adversarial review (⇧⌘F): pick the PR apart and report, don't fix it.")
                }
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
                    InfoLabel("Folder to scan", "A folder holding your git checkouts. Stoplight walks it and matches each clone's remote to the repos your PRs live in.")
                }
                if model.prefs.repoPaths.isEmpty {
                    Text("No clones found yet. Scan a folder that holds your git checkouts; remotes are matched to the PRs' repos.")
                        .foregroundStyle(.secondary).font(.callout)
                } else {
                    ForEach(model.prefs.repoPaths.sorted(by: { $0.key < $1.key }), id: \.key) { slug, path in
                        HStack {
                            Text(slug)
                            Spacer()
                            Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button { prefs.repoPaths[slug] = nil } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Forget")
                        }
                    }
                }
            } header: {
                Text("Repos")
            } footer: {
                Text("A repo needs a clone here before its PRs can go to the agent. Worktrees are created beside it as repo-branch.")
            }
        }
        .formStyle(.grouped)
        .task { if !detected { await model.detectAgents(); detected = true } }
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
