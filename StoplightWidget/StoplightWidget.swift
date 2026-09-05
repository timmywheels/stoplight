import WidgetKit
import SwiftUI
import OSLog
import StoplightCore

private let log = Logger(subsystem: "com.timwheeler.stoplight.widget", category: "timeline")

/// US-007. Reads prs.json from the App Group. Never touches the network.
struct Entry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot?
}

/// WidgetKit's completion handlers aren't Sendable; we only ever call them once, from one task.
private struct Once<T>: @unchecked Sendable { let call: T }

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: Snapshot(prs: Self.sample))
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        if context.isPreview { completion(Entry(date: .now, snapshot: Snapshot(prs: Self.sample))); return }
        let done = Once(call: completion)
        Task { done.call(Entry(date: .now, snapshot: await SharedStore.load())) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // The app calls reloadAllTimelines after every fetch; this policy is only a fallback tick.
        let done = Once(call: completion)
        Task {
            let snap = await SharedStore.load()
            log.notice("getTimeline: prs=\(snap?.prs.count ?? -1)")
            let entry = Entry(date: .now, snapshot: snap)
            // No data yet (app not running / not signed in): retry every minute instead of every 15.
            let next: TimeInterval = snap == nil ? 60 : 15 * 60
            done.call(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(next))))
        }
    }

    static let sample: [PullRequest] = [
        PullRequest(id: "1", repo: "acme/api", number: 412, title: "Add rate limiting to auth endpoints",
                    url: URL(string: "https://github.com")!, isDraft: false, updatedAt: .now, headSha: "a",
                    checks: [CheckResult(name: "test", state: .failure, url: nil)]),
        PullRequest(id: "2", repo: "acme/web", number: 88, title: "Fix flaky checkout test",
                    url: URL(string: "https://github.com")!, isDraft: false, updatedAt: .now, headSha: "b",
                    checks: [CheckResult(name: "build", state: .pending, url: nil)]),
        PullRequest(id: "3", repo: "acme/infra", number: 9, title: "Bump node to 22",
                    url: URL(string: "https://github.com")!, isDraft: false, updatedAt: .now, headSha: "c",
                    checks: [CheckResult(name: "lint", state: .success, url: nil)]),
    ]
}

struct StoplightWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        if let snap = entry.snapshot {
            switch family {
            case .systemMedium: ListView(snapshot: snap, maxRows: 4)
            case .systemLarge: ListView(snapshot: snap, maxRows: 12)
            default: SmallView(snapshot: snap)
            }
        } else {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.secondary.opacity(0.25)).frame(width: 14, height: 14) }
                }
                Text("Open Stoplight and sign in").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }
}

func stateColor(_ s: CIState) -> Color {
    switch s {
    case .failure: .red
    case .pending: .yellow
    case .success: .green
    case .none: .secondary
    }
}

struct SmallView: View {
    let snapshot: Snapshot
    private var live: [PullRequest] { snapshot.counted.filter { !$0.isDraft } }
    private func count(_ s: CIState) -> Int { live.filter { $0.state == s }.count }

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                light(.failure, "failed")
                light(.pending, "running")
                light(.success, "passed")
            }
            Spacer(minLength: 0)
            if snapshot.isStale {
                Text(snapshot.writtenAt, style: .relative).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .widgetURL(URL(string: "stoplight://open"))
    }

    private func light(_ s: CIState, _ label: String) -> some View {
        let n = count(s)
        return VStack(spacing: 6) {
            Circle()
                .fill(n > 0 ? stateColor(s) : Color.secondary.opacity(0.25))
                .frame(width: 22, height: 22)
            Text("\(n)").font(.system(.title3, design: .rounded).monospacedDigit().weight(.semibold))
                .foregroundStyle(n > 0 ? .primary : .tertiary)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Medium and large: the popover's sections, in the popover's order, with the same rows (US-023).
struct ListView: View {
    let snapshot: Snapshot
    let maxRows: Int

    /// "#439" when every row in the section is from one repo; "servicepro #439" when repos differ.
    private func refLabel(_ row: (section: Snapshot.Section, pr: PullRequest), in rows: [(section: Snapshot.Section, pr: PullRequest)]) -> String {
        let repos = Set(rows.filter { $0.section.id == row.section.id }.map { $0.pr.repo.lowercased() })
        if repos.count <= 1 { return "#\(row.pr.number)" }
        let name = row.pr.repo.split(separator: "/").last.map(String.init) ?? row.pr.repo
        return "\(name) #\(row.pr.number)"
    }

    var body: some View {
        let rows = Array(snapshot.orderedRows.prefix(maxRows))
        let showHeaders = Set(rows.map(\.section.id)).count > 1 || rows.first?.section.title != "Mine"
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.element.pr.id) { i, row in
                if showHeaders && (i == 0 || rows[i - 1].section.id != row.section.id) && !row.section.title.isEmpty {
                    Text(row.section.title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.top, i == 0 ? 0 : 4)
                }
                Link(destination: URL(string: "stoplight://pr/\(row.pr.id)") ?? row.pr.url) {
                    HStack(spacing: 8) {
                        if row.pr.status == .merged && row.pr.checks.isEmpty {
                            Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(.purple).frame(width: 8)
                        } else {
                            Circle().fill(stateColor(row.pr.state)).frame(width: 8, height: 8)
                        }
                        if snapshot.pinnedIDs.contains(row.pr.id) {
                            Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(refLabel(row, in: rows)).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        Text(row.pr.title).font(.caption).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            if rows.isEmpty {
                Text("No open PRs").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if snapshot.isStale {
                HStack { Spacer(); Text(snapshot.writtenAt, style: .relative).font(.caption2).foregroundStyle(.tertiary) }
            }
        }
    }
}

struct StoplightWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StoplightStatus", provider: Provider()) { entry in
            StoplightWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Stoplight")
        .description("CI status for your open pull requests.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct StoplightWidgetBundle: WidgetBundle {
    var body: some Widget { StoplightWidget() }
}
