import SwiftUI

/// System Settings' little ⓘ. Hover for the tooltip, click for a popover that stays put
/// long enough to read. Used wherever a setting's name can't carry its meaning.
struct InfoTip: View {
    let text: String
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(hovering || showing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(text)
        .accessibilityLabel("More information")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(12)
        }
    }
}

/// A control's label with its ⓘ beside it. Empty explanation means no icon.
struct InfoLabel: View {
    let title: String
    let text: String
    init(_ title: String, _ text: String) { self.title = title; self.text = text }

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            if !text.isEmpty { InfoTip(text: text) }
        }
    }
}
