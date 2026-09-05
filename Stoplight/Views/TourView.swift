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
        Slide(title: "Three dots, one answer",
              body: "Red: something failed. Yellow: checks running. Green: all passed. Each dot lights when any of your PRs is in that state.",
              art: AnyView(HStack(spacing: 10) {
                  Circle().fill(.red).frame(width: 14, height: 14)
                  Circle().fill(.yellow).frame(width: 14, height: 14)
                  Circle().fill(.green).frame(width: 14, height: 14)
              }.padding(.horizontal, 14).padding(.vertical, 10).background(Color(white: 0.22), in: Capsule()))),
        Slide(title: "Click a PR to expand it",
              body: "Description, failing checks, and buttons for Open, Copy URL, Share, Pin. Double-click or ⌘-click opens the PR on GitHub. Swap those two in Settings.",
              art: AnyView(HStack(spacing: 10) {
                  ForEach(["arrow.up.right", "doc.on.doc", "square.and.arrow.up", "pin"], id: \.self) { name in
                      Image(systemName: name).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                          .frame(width: 32, height: 32).background(.quaternary, in: Circle())
                  }
              })),
        Slide(title: "Right-click for the rest",
              body: "Nickname a PR, hide it, follow its author, copy a whole stack as Markdown. Click a section header to collapse it, drag one to reorder.",
              art: AnyView(Image(systemName: "contextualmenu.and.cursorarrow").font(.system(size: 34)).foregroundStyle(.secondary))),
        Slide(title: "Follow your team",
              body: "Settings → Sources: follow people, repos, or orgs and each gets its own section. Hide bots and noisy repos. The desktop widget mirrors whatever you set up here.",
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
