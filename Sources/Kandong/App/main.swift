import AppKit

// A menu-bar app: no Dock icon, no main menu beyond the status item.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    #if DEBUG
    if let flag = CommandLine.arguments.firstIndex(of: "--render-panel") {
        // Renders the Result panel to PNGs and quits: no window, status item or shortcuts.
        let folder = CommandLine.arguments.dropFirst(flag + 1).first ?? "panel-snapshots"
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await PanelSnapshots.render(to: URL(fileURLWithPath: folder))
            exit(0)
        }
        app.run()
    }
    #endif
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
