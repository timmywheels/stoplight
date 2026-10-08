import SwiftUI

/// One line of text that, when it doesn't fit and `active` stays on for a moment, slides once to
/// show its end, rests, and slides back. Never loops; text that fits never moves. With Reduce
/// Motion it stays put (the expanded row shows the full text). Reports whether it's cut off.
struct MarqueeText: View {
    let text: String
    var active: Bool
    @Binding var truncated: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fullWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var sliding = false
    @State private var run: Task<Void, Never>?

    private var overflow: CGFloat { max(0, fullWidth - boxWidth) }

    var body: some View {
        // The truncated title always sets the size. The sliding copy is an overlay, which can't
        // change layout: drawn in-line at full width it widened the row, and the whole list shifted.
        Text(text).lineLimit(1).truncationMode(.tail)
            .opacity(sliding ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if sliding { Text(text).lineLimit(1).fixedSize().offset(x: offset) }
            }
            .clipped()
        .background(alignment: .leading) {
            // The width the text would like, measured off screen; and the width it's given.
            Text(text).lineLimit(1).fixedSize().hidden()
                .background(GeometryReader { g in Color.clear.onChange(of: g.size.width, initial: true) { _, w in fullWidth = w; report() } })
        }
        .background(GeometryReader { g in Color.clear.onChange(of: g.size.width, initial: true) { _, w in boxWidth = w; report() } })
        .onChange(of: active) { _, on in on ? start() : stop() }
        .onDisappear { run?.cancel() }
    }

    private func report() {
        let cut = overflow > 1
        if cut != truncated { truncated = cut }
    }

    private func start() {
        guard !reduceMotion, overflow > 1 else { return }
        run?.cancel()
        run = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))   // a pass-by isn't a hover
            guard !Task.isCancelled else { return }
            let travel = Double(overflow) / 40 + 0.3            // ~40pt a second, never a jump
            sliding = true
            withAnimation(.easeInOut(duration: travel)) { offset = -overflow }
            try? await Task.sleep(for: .seconds(travel + 1.0)) // rest on the end
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: travel * 0.6)) { offset = 0 }
            try? await Task.sleep(for: .seconds(travel * 0.6))
            guard !Task.isCancelled else { return }
            sliding = false
        }
    }

    private func stop() {
        run?.cancel()
        guard sliding else { return }
        withAnimation(.easeOut(duration: 0.2)) { offset = 0 }
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(200)); if offset == 0 { sliding = false } }
    }
}
