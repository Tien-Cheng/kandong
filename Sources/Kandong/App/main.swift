import AppKit

// A menu-bar app: no Dock icon, no main menu beyond the status item.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    #if DEBUG
    if let flag = CommandLine.arguments.firstIndex(of: "--render-chatgpt-settings") {
        let folder = CommandLine.arguments.dropFirst(flag + 1).first ?? "chatgpt-snapshots"
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await ChatGPTSnapshots.render(to: URL(fileURLWithPath: folder))
            exit(0)
        }
        app.run()
    }
    if let flag = CommandLine.arguments.firstIndex(of: "--render-settings") {
        let folder = CommandLine.arguments.dropFirst(flag + 1).first ?? "settings-snapshots"
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await SettingsSnapshots.render(to: URL(fileURLWithPath: folder))
            exit(0)
        }
        app.run()
    }
    if CommandLine.arguments.contains("--time-panel") {
        // Times the Result panel's content, offscreen, and quits.
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await PanelTimings.run()
            exit(0)
        }
        app.run()
    }
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
    // A debug flag this build doesn't know must not start the real app, with its shortcuts and History.
    if let unknown = CommandLine.arguments.dropFirst().first(where: { $0.hasPrefix("--") }) {
        print("Unknown option \(unknown)")
        exit(2)
    }
    #endif
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
