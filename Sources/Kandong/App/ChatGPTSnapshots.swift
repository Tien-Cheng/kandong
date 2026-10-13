#if DEBUG
import AppKit
import SwiftUI
import KandongKit

/// Native settings snapshots using fictitious account metadata, without opening a browser or Keychain.
@MainActor
enum ChatGPTSnapshots {
    static func render(to folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scopes = ["openid", "email", "chatgpt.tokens.use.direct"]
        let connected = ChatGPTAccount(clientID: "oaiapp_preview", issuer: "https://auth.openai.com", subject: "preview",
                                      email: "learner@example.com", scopes: scopes, isSignedIn: true)
        var permissionMissing = connected
        permissionMissing.scopes = ["openid", "email"]
        let scenarios: [(String, [ChatGPTAccount], BackendStatus, Bool)] = [
            ("signed-out", [], .needsSetup("Continue with ChatGPT to connect your plan.", fix: .connectChatGPT), false),
            ("connected", [connected], .ready("Using ChatGPT plan · Account model"), false),
            ("permission-missing", [permissionMissing], .needsSetup("Enable ChatGPT plan usage to translate.", fix: .connectChatGPT), false),
            ("signing-in", [], .needsSetup("Continue with ChatGPT to connect your plan.", fix: .connectChatGPT), true),
        ]
        for (name, accounts, status, connecting) in scenarios {
            var settings = AppSettings()
            settings.chatGPT.accountID = accounts.first?.id
            if !accounts.isEmpty { settings.chatGPT.model = "Account model" }
            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("kandong-chatgpt-preview-\(UUID())")
            let model = AppModel(previewSettings: settings, workspacePath: workspace.path)
            model.prepareChatGPTPreview(accounts: accounts, status: status, connecting: connecting)
            let state = MainWindowState()
            state.tab = .ai
            state.backendID = BackendConfig.chatGPT.id
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for width: CGFloat in [760, 960] {
                    let dark = appearance == .darkAqua
                    let view = MainView(model: model, state: state)
                        .frame(width: width, height: 800)
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: view)
                    host.appearance = NSAppearance(named: appearance)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 800)
                    host.layoutSubtreeIfNeeded()
                    try? await Task.sleep(for: .milliseconds(300))
                    host.layoutSubtreeIfNeeded()
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
                    let url = folder.appendingPathComponent("\(name)-\(Int(width))-\(dark ? "dark" : "light").png")
                    try? png.write(to: url)
                    print(url.path)
                }
            }
            try? FileManager.default.removeItem(at: workspace)
        }
    }
}
#endif
