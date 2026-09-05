import AppKit
import OSLog
import ServiceManagement
import SwiftUI
import StoplightCore

private let log = Logger(subsystem: "com.timwheeler.stoplight", category: "Panel")

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
    private var keyMonitor: Any?
    private var globalHotkey: GlobalHotkey?

    private static let sizeKey = "panelSize"
    private static let defaultSize = NSSize(width: 380, height: 520)
    private static let minSize = NSSize(width: 320, height: 160)
    /// Set once the user drags the panel; we then stop snapping it under the dots until it's closed unpinned.
    private var userMoved = false
    private var fitting = false

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        observeGlyph()
        observeContent()
        model.openPanel = { [weak self] in self?.open() }
        globalHotkey = GlobalHotkey { [weak self] in self?.toggle() }
    }

    /// Shrink to fit when sections collapse; grow back up to the user's chosen height when they expand (US-027).
    private func observeContent() {
        withObservationTracking {
            _ = model.contentHeight
            _ = model.pinnedPanel
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.fitToContent()
                self.applyPinState()
                self.observeContent()
            }
        }
    }

    /// Chrome = everything that isn't the scrolling list (footer, dividers). Measured once the panel exists.
    private var chromeHeight: CGFloat = 46

    private func fitToContent() {
        guard let panel, panel.isVisible, !panel.inLiveResize, model.contentHeight > 0 else { return }
        let maxH = savedSize().height
        let wanted = max(Self.minSize.height, min(maxH, model.contentHeight + chromeHeight))
        guard abs(wanted - panel.frame.height) > 1 else { return }
        fitting = true
        var f = panel.frame
        f.origin.y += f.height - wanted   // keep the top edge where it is
        f.size.height = wanted
        panel.setFrame(f, display: true, animate: true)
        fitting = false
    }

    private func applyPinState() {
        guard let panel else { return }
        panel.level = model.pinnedPanel ? .floating : .popUpMenu
        if model.pinnedPanel, let m = clickOutsideMonitor { NSEvent.removeMonitor(m); clickOutsideMonitor = nil }
        if !model.pinnedPanel, panel.isVisible, clickOutsideMonitor == nil { installClickOutside() }
    }

    private func installClickOutside() {
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                // A press inside our own frame is never "outside", whatever delivered it.
                if panel.frame.contains(NSEvent.mouseLocation) { return }
                self.close(reason: "click outside (global monitor, window \(event.windowNumber))")
            }
        }
    }

    /// Left click toggles the panel; right click shows a small utility menu.
    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() } else { toggle() }
    }

    private func showMenu() {
        close(reason: "right-click menu")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Tour", action: #selector(showTour), keyEquivalent: "").target = self
        let hk = menu.addItem(withTitle: "Keyboard Shortcuts", action: #selector(showHotkeys), keyEquivalent: "/")
        hk.target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        let pin = menu.addItem(withTitle: "Pin Panel Open", action: #selector(togglePin), keyEquivalent: "")
        pin.target = self
        pin.state = model.pinnedPanel ? .on : .off
        menu.addItem(withTitle: "Reset Panel Position and Size", action: #selector(resetPanel), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Stoplight", action: #selector(quit), keyEquivalent: "q").target = self
        // Attach just long enough to pop it up, so left click keeps toggling the panel.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func showTour() {
        model.prefs.tourSeen = false
        open()
    }

    @objc private func togglePin() {
        model.pinnedPanel.toggle()
        if model.pinnedPanel { open() }
    }

    /// Back under the dots at the default size, unpinned.
    @objc private func resetPanel() {
        model.pinnedPanel = false
        userMoved = false
        UserDefaults.standard.removeObject(forKey: Self.sizeKey)
        if let panel {
            panel.setContentSize(Self.defaultSize)
            position(panel)
        }
        open()
    }

    @objc private func showHotkeys() {
        model.showHotkeys = true
        open()
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

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
        if let panel, panel.isVisible { close(reason: "status item click") } else { open() }
    }

    func open() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !userMoved { position(panel) }
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        model.panelVisible = true
        fitToContent()
        if !model.pinnedPanel { installClickOutside() }
        // Keyboard: dispatch through the Hotkey table while the panel is key. Text fields keep their keys.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            // Typing in a field: every key, Esc included, belongs to the field (Esc dismisses the field itself).
            if panel.firstResponder is NSTextView { return event }
            guard let key = Hotkey.match(event) else { return event }
            if key == .close { self.forceClose(); return nil }
            return MainActor.assumeIsolated { self.model.handle(key) } ? nil : event
        }
    }

    func close(reason: String = "unspecified") {
        if model.pinnedPanel { return }  // pinned panels only close via the pin button or Esc
        log.notice("close: \(reason, privacy: .public)")
        panel?.orderOut(nil)
        model.panelVisible = false
        statusItem.button?.highlight(false)
        userMoved = false
        if let m = clickOutsideMonitor { NSEvent.removeMonitor(m); clickOutsideMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
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
        // Moving is the grab handle's job only (see DragHandle); the background stays inert.
        panel.isMovableByWindowBackground = false
        panel.isMovable = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = Self.minSize
        panel.delegate = self

        let host = MovableHostingView(rootView: PanelRoot(model: model, close: { [weak self] in self?.forceClose() }))
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
        // The user's size is the ceiling: width always, height as the max the list may grow to.
        UserDefaults.standard.set(NSStringFromSize(panel.frame.size), forKey: Self.sizeKey)
        if !userMoved { position(panel) }
        fitToContent()
    }

    func windowDidMove(_ notification: Notification) {
        guard !fitting, let panel, panel.isVisible else { return }
        userMoved = true
        log.notice("moved to \(NSStringFromRect(panel.frame), privacy: .public)")
    }

    func windowDidResignKey(_ notification: Notification) {
        // Starting a background drag momentarily drops key status; don't treat that as "clicked away".
        // Re-check shortly after: still not key and not pinned means the user really went elsewhere.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, let panel = self.panel, panel.isVisible, !self.model.pinnedPanel else { return }
            if !panel.isKeyWindow && !panel.inLiveResize && NSEvent.pressedMouseButtons == 0 { self.close(reason: "resigned key") }
        }
    }

    /// Esc on a pinned panel unpins and closes.
    func forceClose() {
        model.pinnedPanel = false
        close(reason: "escape / forced")
    }
}

/// Plain hosting view; only the DragHandle moves the window.
private final class MovableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// The one place you can drag the panel from. Open-hand cursor on hover, closed hand while dragging (US-027).
struct DragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleView { DragHandleView() }
    func updateNSView(_ view: DragHandleView, context: Context) {}

    final class DragHandleView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) {
            NSCursor.closedHand.push()
            window?.performDrag(with: event)
        }
        override func mouseUp(with event: NSEvent) { NSCursor.pop() }
        override func mouseDragged(with event: NSEvent) {}  // performDrag owns the drag
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
