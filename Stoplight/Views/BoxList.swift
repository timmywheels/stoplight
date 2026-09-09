import SwiftUI

/// A bordered, scrolling box of rows.
///
/// This is what `List` gives you anywhere else, but a `List` nested in a `Form` hands its
/// scrolling to the Form's own scroll view and never moves, so Settings draws its own.
struct BoxList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    /// How many rows fit before it scrolls.
    var visibleRows = 6
    var rowHeight: CGFloat = 26
    /// An extra row pinned to the bottom, for the "new entry" field.
    var draft: (() -> AnyView)? = nil
    @ViewBuilder let row: (Item) -> Row

    private var height: CGFloat {
        let n = items.count + (draft == nil ? 0 : 1)
        return CGFloat(min(max(n, 2), visibleRows)) * rowHeight + 2
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    row(item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .frame(height: rowHeight)
                        .background(i.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.04))
                }
                if let draft {
                    draft()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .frame(height: rowHeight)
                }
            }
        }
        .frame(height: height)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }
}

/// The − that appears when the pointer is over a row.
struct RowRemoveButton: View {
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
                .foregroundStyle(hovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.borderless)
        .onHover { hovering = $0 }
        .help(help)
    }
}
