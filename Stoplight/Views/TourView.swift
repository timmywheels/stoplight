import SwiftUI
import StoplightCore

/// First-run tour (US-024). Four slides inside the panel; Skip or Done marks it seen. Replay from Settings.
struct TourView: View {
    let done: () -> Void
    @State private var index = 0
    private static let motion = Animation.snappy(duration: 0.2, extraBounce: 0)

    private struct Slide {
        let title: String
        let body: String
        let art: AnyView
    }

    private let slides: [Slide] = [
        Slide(title: "Stop refreshing GitHub",
              body: "Stoplight watches every open PR you have. Red means go fix something. Yellow means keep working, it's still running. Green means ship it. One glance at the menu bar is the whole check.",
              art: AnyView(HStack(spacing: 10) {
                  Circle().fill(.red).frame(width: 14, height: 14)
                  Circle().fill(.yellow).frame(width: 14, height: 14)
                  Circle().fill(.green).frame(width: 14, height: 14)
              }.padding(.horizontal, 14).padding(.vertical, 10).background(Color(white: 0.22), in: Capsule()))),
        Slide(title: "Everything about a PR, one click away",
              body: "Click a PR to see its description, exactly which checks failed, and buttons to open, copy, share, or pin it. Double-click opens it on GitHub. Swap those two in Settings.",
              art: AnyView(HStack(spacing: 10) {
                  ForEach(["arrow.up.right", "doc.on.doc", "square.and.arrow.up", "pin"], id: \.self) { name in
                      Image(systemName: name).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                          .frame(width: 32, height: 32).background(.quaternary, in: Circle())
                  }
              })),
        Slide(title: "Make it yours",
              body: "Right-click to nickname a PR, hide the ones that just sit there, or copy a whole stack as Markdown to share. Collapse sections, drag them into your order.",
              art: AnyView(Image(systemName: "contextualmenu.and.cursorarrow").font(.system(size: 34)).foregroundStyle(.secondary))),
        Slide(title: "Watch your team, not just yourself",
              body: "Follow people, repos, or orgs in Settings → Sources and each gets its own section. You get a notification the moment CI fails, or goes green. The desktop widget shows the same list.",
              art: AnyView(Image(systemName: "person.2").font(.system(size: 34)).foregroundStyle(.secondary))),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                slides[index].art.frame(height: 48)
                Text(slides[index].title).font(.headline)
                Text(slides[index].body).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .id(index)
            .transition(.opacity)
            .padding(.horizontal, 28)
            .frame(maxWidth: 360)
            Spacer()
            HStack {
                Button("Skip", action: done).buttonStyle(.plain).foregroundStyle(.secondary)
                    .opacity(index == slides.count - 1 ? 0 : 1)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<slides.count, id: \.self) { i in
                        Circle().fill(i == index ? Color.primary : Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
                    }
                }
                Spacer()
                Button(index == slides.count - 1 ? "Done" : "Next") {
                    if index == slides.count - 1 { done() } else { withAnimation(Self.motion) { index += 1 } }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .onExitCommand(perform: done)
    }
}
