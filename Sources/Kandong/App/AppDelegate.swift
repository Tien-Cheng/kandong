import AppKit
import SwiftUI
import KandongKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static private(set) weak var shared: AppDelegate?

    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private let windowState = MainWindowState()
    /// Sparkle, once launched (nil when running from `swift run`).
    private(set) var updater: Updater?

    // The model exists before launch finishes: a kandong:// link that launched the app arrives
    // between will- and didFinishLaunching.
    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.shared = self
        model = AppModel()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        if Updater.isAvailable { updater = Updater() }
        if !Permissions.accessibilityGranted {
            Permissions.requestAccessibility()
            showMainWindow(tab: .settings)
            relaunchWhenAccessibilityGranted()
        }
    }

    /// macOS only delivers global key events (Esc to close, the tap key) to processes that were
    /// trusted at launch, so restart once the user grants Accessibility.
    private func relaunchWhenAccessibilityGranted() {
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { timer in
            guard Permissions.accessibilityGranted else { return }
            timer.invalidate()
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
            try? relaunch.run()
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

    /// `kandong://lookup?text=…[&local=1]`, `kandong://clipboard`, `kandong://selection`,
    /// `kandong://capture`, `kandong://ai[?backend=<id>]`, `kandong://settings`,
    /// `kandong://check-for-updates` — for Raycast,
    /// Shortcuts, scripts and agents.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "kandong" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let local = query.contains { $0.name == "local" && ($0.value == "1" || $0.value == "true") }
            switch url.host {
            case "lookup":
                if let text = query.first(where: { $0.name == "text" })?.value, !text.isEmpty {
                    model.lookup(text: text, source: .otherApp, local: local,
                                 anchor: CGRect(origin: NSEvent.mouseLocation, size: .zero))
                }
            case "clipboard": model.perform(.lookupClipboard, local: local)
            case "selection": model.perform(.lookupSelection, local: local)
            case "capture": model.perform(.captureScreen, local: local)
            case "settings": showMainWindow(tab: .settings)
            case "check-for-updates": updater?.checkForUpdates()
            case "ai":
                if let id = query.first(where: { $0.name == "backend" })?.value, model.settings.backend(id: id) != nil {
                    windowState.backendID = id
                }
                showMainWindow(tab: .ai)
            default: break
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(tab: windowState.tab)
        return true
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "character.book.closed.zh", accessibilityDescription: "Kandong")
            ?? NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "Kandong")
        image?.isTemplate = true
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let hotkeys = model.settings.hotkeys
        func item(_ title: String, _ action: HotkeyAction, local: Bool = false) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = [action.rawValue, local] as [Any]
            if let combo = hotkeys[action] {
                menuItem.title += "    " + (local ? combo.withShift : combo).displayString
            }
            return menuItem
        }
        menu.addItem(item("Look Up Selection", .lookupSelection))
        menu.addItem(item("Capture Screen Region", .captureScreen))
        menu.addItem(item("Look Up Clipboard", .lookupClipboard))
        menu.addItem(.separator())
        let localHeader = NSMenuItem(title: "With Local backend (\(model.settings.backend(local: true).name))", action: nil, keyEquivalent: "")
        localHeader.isEnabled = false
        menu.addItem(localHeader)
        menu.addItem(item("Look Up Selection", .lookupSelection, local: true))
        menu.addItem(item("Capture Screen Region", .captureScreen, local: true))
        menu.addItem(.separator())
        menu.addItem(menuItem("History", #selector(openHistory)))
        menu.addItem(menuItem("Vocabulary", #selector(openVocabulary)))
        menu.addItem(menuItem("Terms", #selector(openTerms)))
        menu.addItem(menuItem("AI Backends", #selector(openAI)))
        menu.addItem(menuItem("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        if let updater {
            if let version = updater.pendingVersion {
                menu.addItem(menuItem("Restart to Update to \(version)", #selector(restartToUpdate)))
            }
            menu.addItem(menuItem("Check for Updates…", #selector(checkForUpdates)))
        }
        if let error = model.dictionaryError {
            let warning = NSMenuItem(title: "⚠︎ " + error, action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }
        menu.addItem(menuItem("Quit Kandong", #selector(quit), key: "q"))
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [Any], let raw = info.first as? String,
              let action = HotkeyAction(rawValue: raw), let local = info.last as? Bool
        else { return }
        // Let the menu close (and focus return to the previous app) before reading the selection.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [model] in
            model?.perform(action, local: local)
        }
    }

    @objc private func openHistory() { showMainWindow(tab: .history) }
    @objc private func openVocabulary() { showMainWindow(tab: .vocabulary) }
    @objc private func openTerms() { showMainWindow(tab: .terms) }
    @objc private func openAI() { showMainWindow(tab: .ai) }
    @objc private func openSettings() { showMainWindow(tab: .settings) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func checkForUpdates() { updater?.checkForUpdates() }
    @objc private func restartToUpdate() { updater?.restartToUpdate() }

    // MARK: Main window

    func showMainWindow(tab: MainTab) {
        windowState.tab = tab
        if mainWindow == nil {
            // The sidebar layout puts its toggle and title in the window's toolbar; without a real
            // toolbar it draws a stand-in strip over the top of the content.
            let controller = NSHostingController(rootView: MainView(model: model, state: windowState) { [weak self] title in
                self?.mainWindow?.title = title
            })
            controller.sceneBridgingOptions = [.toolbars]
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbar = NSToolbar(identifier: "MainWindow")
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 820, height: 600))
            window.title = windowState.tab.title
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("MainWindow")
            if !window.setFrameUsingName("MainWindow") { window.center() }
            mainWindow = window
        }
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
    }
}
