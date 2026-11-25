#if DEBUG
import AppKit
import SwiftUI
import KandongKit

/// `Kandong --render-settings <folder>` (debug builds only): renders the top of Settings in each state
/// of opening at login, light and dark, to PNGs, without asking macOS about login items.
@MainActor
enum SettingsSnapshots {
    static func render(to folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scenarios: [(String, LoginItem)] = [
            ("off", LoginItem(preview: .off)),
            ("on", LoginItem(preview: .on)),
            ("blocked", LoginItem(preview: .blocked)),
            ("unavailable", LoginItem(preview: .unavailable)),
            ("failed", LoginItem(preview: .off, errorMessage: "The operation couldn’t be completed. Operation not permitted")),
        ]
        for (name, loginItem) in scenarios {
            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("kandong-settings-preview-\(UUID())")
            let model = AppModel(previewSettings: AppSettings(), workspacePath: workspace.path, loginItem: loginItem)
            let state = MainWindowState()
            state.tab = .settings
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let dark = appearance == .darkAqua
                let view = MainView(model: model, state: state)
                    .frame(width: 820, height: 600)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: appearance)
                host.frame = NSRect(x: 0, y: 0, width: 820, height: 600)
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(300))
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
                let url = folder.appendingPathComponent("open-at-login-\(name)-\(dark ? "dark" : "light").png")
                try? png.write(to: url)
                print(url.path)
            }
            try? FileManager.default.removeItem(at: workspace)
        }
    }
}
#endif
