import SwiftUI

/// The shortcuts sheet (⌘/ or right-click → Keyboard Shortcuts). Generated from the `Hotkey` table.
struct HotkeysView: View {
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts").font(.headline)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction).controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Hotkey.groups, id: \.0) { group, keys in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(keys, id: \.self) { k in
                                HStack {
                                    Text(k.title).font(.callout)
                                    Spacer()
                                    Text(k.display).font(.system(.callout, design: .rounded).monospaced())
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .onExitCommand(perform: done)
    }
}
