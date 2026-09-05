import AppKit
import SwiftUI
import StoplightCore

/// Owns the status item and the drop-down panel (US-004/005).
///
/// Why not `MenuBarExtra`: its window can't be resized, doesn't remember size, and sizes itself to
/// the view's ideal height, which is what made the list collapse earlier. An `NSPanel` that
/// doesn't activate the app gives a real resizable window that still behaves like a menu:
/// opens under the dots, closes on click-outside or Escape.
@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?

    private static let sizeKey = "panelSize"
    private static let defaultSize = NSSize(width: 380, height: 520)
    private static let minSize = NSSize(width: 320, height: 240)

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseUp])
        }
        observeGlyph()
    }

    // MARK: Glyph

    /// Re-render the dots whenever anything they depend on changes.
    private func observeGlyph() {
        withObservationTracking {
            statusItem.button?.image = StatusGlyph.image(for: model.presence, count: model.badgeCount,
                                                         pop: model.bob, housing: model.prefs.housing)
            statusItem.button?.toolTip = statusItem.button?.image?.accessibilityDescription
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeGlyph() }
        }
    }

    // MARK: Panel

    @objc private func toggle() {
        if let panel, panel.isVisible { close() } else { open() }
    }

    func open() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    func close() {
        panel?.orderOut(nil)
        statusItem.button?.highlight(false)
        if let m = clickOutsideMonitor { NSEvent.removeMonitor(m); clickOutsideMonitor = nil }
    }

    private func makePanel() -> NSPanel {
        let size = savedSize()
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = false
        panel.isMovable = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = Self.minSize
        panel.delegate = self

        let host = NSHostingView(rootView: PanelRoot(model: model, close: { [weak self] in self?.close() }))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.safeAreaRegions = []  // no inset for the hidden title bar
        host.sizingOptions = []    // the user sizes the panel; content never resizes the window
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        return panel
    }

    /// Under the status item, right edges aligned, clamped to the screen.
    private func position(_ panel: NSPanel) {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        // Never taller than the screen below the menu bar.
        var size = panel.frame.size
        size.height = min(size.height, buttonFrame.minY - 6 - visible.minY - 8)
        size.width = min(size.width, visible.width - 16)
        var origin = NSPoint(x: buttonFrame.maxX - size.width, y: buttonFrame.minY - size.height - 6)
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
        origin.y = max(visible.minY + 8, origin.y)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // MARK: Size persistence

    private func savedSize() -> NSSize {
        guard let s = UserDefaults.standard.string(forKey: Self.sizeKey) else { return Self.defaultSize }
        let size = NSSizeFromString(s)
        return size.width >= Self.minSize.width && size.height >= Self.minSize.height ? size : Self.defaultSize
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromSize(panel.frame.size), forKey: Self.sizeKey)
        position(panel)  // keep the top edge glued to the menu bar after a resize from the bottom
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking another app's window: behave like a menu and go away.
        if NSApp.keyWindow == nil || NSApp.keyWindow !== panel { close() }
    }
}

/// Wraps the popover content so Escape closes the panel and the view fills whatever size the user picked.
private struct PanelRoot: View {
    let model: AppModel
    let close: () -> Void

    var body: some View {
        MenuBarView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .onExitCommand(perform: close)
    }
}
