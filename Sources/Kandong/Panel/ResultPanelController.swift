import AppKit
import Observation
import SwiftUI

/// A floating panel that never activates the app, so focus stays in whatever the user was reading.
final class ResultPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

@MainActor
@Observable
final class ResultPanelController {
    @ObservationIgnored private let panel: ResultPanel
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private unowned let model: AppModel
    var isPinned = false

    init(model: AppModel) {
        self.model = model
        let panel = ResultPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
            backing: .buffered, defer: true
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = NSSize(width: 340, height: 220)
        panel.setFrameAutosaveName("ResultPanel")
        self.panel = panel
        panel.contentView = NSHostingView(rootView: ResultView(model: model, controller: self))
    }

    var isVisible: Bool { panel.isVisible }

    /// Shows the panel just below `anchor` (screen coordinates), or where it was if pinned/no anchor.
    func show(near anchor: CGRect?) {
        if let anchor, !isPinned || !panel.isVisible {
            position(below: anchor)
        }
        panel.orderFrontRegardless()
        installMonitors()
    }

    func close() {
        panel.orderOut(nil)
        removeMonitors()
        Speech.stopIfNeeded()
    }

    func togglePin() {
        isPinned.toggle()
    }

    private func position(below anchor: CGRect) {
        let point = CGPoint(x: anchor.midX, y: anchor.minY)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = min(max(anchor.minX, visible.minX + 8), visible.maxX - frame.width - 8)
        let below = anchor.minY - 10 - frame.height
        if below >= visible.minY + 8 {
            frame.origin.y = below
        } else {
            frame.origin.y = min(anchor.maxY + 10, visible.maxY - frame.height - 8)
        }
        frame.origin.y = max(frame.origin.y, visible.minY + 8)
        panel.setFrame(frame, display: true)
    }

    /// Esc closes; a click elsewhere closes unless pinned.
    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { MainActor.assumeIsolated { self?.close() } }
        }) {
            monitors.append(keys)
        }
        if let clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isPinned else { return }
                self.close()
            }
        }) {
            monitors.append(clicks)
        }
        if let localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            // Kandong itself may be active (e.g. after a kandong:// URL); Esc then arrives here
            // with no window or the panel as target. Leave Esc alone in the main window.
            guard event.keyCode == 53, event.window == nil || event.window === self?.panel else { return event }
            MainActor.assumeIsolated { self?.close() }
            return nil
        }) {
            monitors.append(localKeys)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }
}
