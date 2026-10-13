import AppKit
import Observation
import SwiftUI
import KandongKit

/// A floating panel that never activates the app, so the app the user was reading stays in front.
/// It takes the keyboard while shown, without activating Kandong, the way Spotlight does.
final class ResultPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc, handled by the controller (it first clears a selected word).
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
@Observable
final class ResultPanelController: NSObject, NSWindowDelegate {
    @ObservationIgnored private let panel: ResultPanel
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private unowned let model: AppModel
    var isPinned = false
    /// The word picked in the Reading (by click or ←/→), shown in the word card; a Segment id.
    var selectedWordID: Int?

    /// Which edge stays put as the panel grows to fit: the top when it opened below the selection,
    /// the bottom when there was only room above it.
    @ObservationIgnored private var fixedEdge: NSRectEdge = .maxY
    /// Set when the user drags the panel's height; it then keeps that height until the next Lookup.
    @ObservationIgnored private var userSizedHeight = false
    /// The height the content last asked for, applied once the current layout pass is over.
    @ObservationIgnored private var pendingHeight: CGFloat?

    static let cornerRadius: CGFloat = 16

    init(model: AppModel) {
        self.model = model
        let panel = ResultPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
            backing: .buffered, defer: true
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = NSSize(width: 360, height: 180)
        panel.setFrameAutosaveName("ResultPanel")
        // Liquid Glass: the panel itself is glass, like a system popover; its content sits on a
        // solid sheet inside (see ResultView) so the Reading never depends on what's behind it.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        self.panel = panel
        super.init()
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.escape() }
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = Self.cornerRadius
        let host = NSHostingView(rootView: ResultView(model: model, controller: self))
        // The controller sizes the panel (see `fit`); the hosting view mustn't also push its own size
        // into the window's constraints, or the two fight and AppKit gives up mid-layout.
        host.sizingOptions = []
        glass.contentView = host
        panel.contentView = glass
    }

    /// The title bar's height, which the header shares, and the room it leaves for the close button.
    var titlebarHeight: CGFloat { max(panel.frame.height - panel.contentLayoutRect.height, 28) }
    var closeButtonInset: CGFloat { (panel.standardWindowButton(.closeButton)?.frame.maxX ?? 22) + 12 }

    var isVisible: Bool { panel.isVisible }
    /// Whether the panel has the keyboard, i.e. the user is still in it rather than back in their app.
    var isKey: Bool { panel.isKeyWindow }

    /// Shows the panel just below `anchor` (screen coordinates), or where it was if pinned/no anchor,
    /// and gives it the keyboard.
    func show(near anchor: CGRect?) {
        selectedWordID = nil
        userSizedHeight = false
        if let anchor, !isPinned || !panel.isVisible {
            position(below: anchor)
        }
        panel.orderFrontRegardless()
        panel.makeKey()
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

    /// Esc: first lets go of a selected word, then closes.
    private func escape() {
        if selectedWordID != nil {
            selectedWordID = nil
        } else {
            close()
        }
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
            fixedEdge = .maxY
        } else {
            frame.origin.y = min(anchor.maxY + 10, visible.maxY - frame.height - 8)
            fixedEdge = .minY
        }
        frame.origin.y = max(frame.origin.y, visible.minY + 8)
        panel.setFrame(frame, display: true)
    }

    // MARK: Fitting the content

    /// Grows or shrinks the panel to show `contentHeight` of scrolling content, of which
    /// `viewportHeight` is visible now; at most 70% of the screen, and never past its edge.
    ///
    /// Called from SwiftUI layout, so the resize waits for the current pass to finish: resizing the
    /// window inside a layout pass (e.g. when a flip swaps the content of a visible panel) makes
    /// AppKit lay out again and again until it throws.
    func fit(contentHeight: CGFloat, viewportHeight: CGFloat) {
        guard panel.isVisible, viewportHeight > 0 else { return }
        let alreadyScheduled = pendingHeight != nil
        pendingHeight = panel.frame.height - viewportHeight + contentHeight
        guard !alreadyScheduled else { return }
        DispatchQueue.main.async { [weak self] in self?.applyPendingHeight() }
    }

    private func applyPendingHeight() {
        guard let wanted = pendingHeight else { return }
        pendingHeight = nil
        guard panel.isVisible, !userSizedHeight, !panel.inLiveResize else { return }
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        var frame = panel.frame
        let room = fixedEdge == .maxY ? frame.maxY - visible.minY - 8 : visible.maxY - frame.minY - 8
        let height = min(max(wanted, panel.minSize.height), visible.height * 0.7, room).rounded()
        guard abs(height - frame.height) > 1 else { return }
        if fixedEdge == .maxY { frame.origin.y = frame.maxY - height }
        frame.size.height = height
        panel.setFrame(frame, display: true, animate: false)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        userSizedHeight = true
    }

    // MARK: Keyboard

    /// The words ←/→ walk through: each word of the Reading, in order.
    private var navigableWords: [Segment] {
        model.session?.analysis?.words ?? []
    }

    var selectedWord: Segment? {
        guard let id = selectedWordID else { return nil }
        return navigableWords.first { $0.id == id }
    }

    func selectWord(step: Int) {
        let words = navigableWords
        guard !words.isEmpty else { return }
        if let id = selectedWordID, let index = words.firstIndex(where: { $0.id == id }) {
            selectedWordID = words[min(max(index + step, 0), words.count - 1)].id
        } else {
            selectedWordID = step < 0 ? words.last?.id : words.first?.id
        }
    }

    /// Keys while the panel has the keyboard; true for keys it handled.
    private func handleKey(_ keyCode: UInt16, characters: String) -> Bool {
        guard let session = model.session else { return false }
        switch keyCode {
        case 123: selectWord(step: -1)   // ←
        case 124: selectWord(step: 1)    // →
        case 49:                         // Space
            if let word = selectedWord { Speech.speak(word.text) } else if let text = session.analysis?.source { Speech.speak(text) }
        default:
            switch characters {
            case "s":
                guard let word = selectedWord, let source = session.analysis?.source else { return false }
                model.toggleSaved(word, sentence: source)
            case "e": model.explain(session)
            case "r": model.flip(session)
            case "p": togglePin()
            default: return false
            }
        }
        return true
    }

    /// Esc closes from anywhere (unless pinned); a click elsewhere closes unless pinned; keys typed
    /// into the panel go to `handle`.
    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.keyCode == 53, !self.isPinned else { return }
                self.close()
            }
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
            // Kandong itself may be active (e.g. after a kandong:// URL); Esc then arrives with no
            // window. Keys in the main window or a popover (the Term editor) are left alone.
            let keyCode = event.keyCode, inPanel = event.window === self?.panel, noWindow = event.window == nil
            let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if keyCode == 53, inPanel || noWindow {
                    self.escape()
                    return true
                }
                return inPanel && plain && self.handleKey(keyCode, characters: characters)
            }
            return handled ? nil : event
        }) {
            monitors.append(localKeys)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }
}
