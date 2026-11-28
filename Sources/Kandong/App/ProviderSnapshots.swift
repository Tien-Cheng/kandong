#if DEBUG
import AppKit
import SwiftUI
import KandongKit

/// Renders native AI settings snapshots for OpenRouter and Claude Backends in light and dark modes
/// without touching Keychain or opening a browser.
@MainActor
enum ProviderSnapshots {
    static func render(to folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let openRouterID = "openrouter-preview"
        let claudeID = "claude-preview"
        let claudeModels = [
            AnthropicModel(id: "claude-sonnet-4-5", displayName: "Claude Sonnet 4.5", supportsImages: true),
            AnthropicModel(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5", supportsImages: true),
            AnthropicModel(id: "claude-opus-4-5", displayName: "Claude Opus 4.5", supportsImages: true),
        ]

        struct Scenario {
            let name: String
            let selectedID: String
            let connectedIDs: Set<String>
            let openRouterConnectingID: String?
            let statuses: [String: BackendStatus]
            let claudeModel: String
            let openRouterModel: String
        }

        let scenarios: [Scenario] = [
            Scenario(
                name: "openrouter-signed-out",
                selectedID: openRouterID,
                connectedIDs: [],
                openRouterConnectingID: nil,
                statuses: [
                    BackendConfig.appleIntelligence.id: .ready("On this Mac"),
                    BackendConfig.chatGPT.id: .needsSetup("Continue with ChatGPT to connect your plan.", fix: .connectChatGPT),
                    "lmstudio": .needsSetup("LM Studio's server isn't running."),
                    openRouterID: .needsSetup("Sign in with OpenRouter or add an API key.", fix: .connectOpenRouter(backendID: openRouterID)),
                    claudeID: .needsSetup("Add your Anthropic API key.", fix: .openURL(AnthropicBackend.consoleKeysURL, label: "Get API Key")),
                ],
                claudeModel: "",
                openRouterModel: ""
            ),
            Scenario(
                name: "openrouter-signing-in",
                selectedID: openRouterID,
                connectedIDs: [],
                openRouterConnectingID: openRouterID,
                statuses: [
                    BackendConfig.appleIntelligence.id: .ready("On this Mac"),
                    BackendConfig.chatGPT.id: .needsSetup("Continue with ChatGPT to connect your plan.", fix: .connectChatGPT),
                    "lmstudio": .needsSetup("LM Studio's server isn't running."),
                    openRouterID: .needsSetup("Sign in with OpenRouter or add an API key.", fix: .connectOpenRouter(backendID: openRouterID)),
                    claudeID: .needsSetup("Add your Anthropic API key.", fix: .openURL(AnthropicBackend.consoleKeysURL, label: "Get API Key")),
                ],
                claudeModel: "",
                openRouterModel: ""
            ),
            Scenario(
                name: "openrouter-connected",
                selectedID: openRouterID,
                connectedIDs: [openRouterID],
                openRouterConnectingID: nil,
                statuses: [
                    BackendConfig.appleIntelligence.id: .ready("On this Mac"),
                    BackendConfig.chatGPT.id: .needsSetup("Continue with ChatGPT to connect your plan.", fix: .connectChatGPT),
                    "lmstudio": .needsSetup("LM Studio's server isn't running."),
                    openRouterID: .ready("anthropic/claude-sonnet-4.5"),
                    claudeID: .needsSetup("Add your Anthropic API key.", fix: .openURL(AnthropicBackend.consoleKeysURL, label: "Get API Key")),
                ],
                claudeModel: "",
                openRouterModel: "anthropic/claude-sonnet-4.5"
            ),
            Scenario(
                name: "claude-needs-key",
                selectedID: claudeID,
                connectedIDs: [],
                openRouterConnectingID: nil,
                statuses: [
                    BackendConfig.appleIntelligence.id: .ready("On this Mac"),
                    BackendConfig.chatGPT.id: .needsSetup("Continue with ChatGPT to connect your plan.", fix: .connectChatGPT),
                    "lmstudio": .needsSetup("LM Studio's server isn't running."),
                    openRouterID: .needsSetup("Sign in with OpenRouter or add an API key.", fix: .connectOpenRouter(backendID: openRouterID)),
                    claudeID: .needsSetup("Add your Anthropic API key.", fix: .openURL(AnthropicBackend.consoleKeysURL, label: "Get API Key")),
                ],
                claudeModel: "",
                openRouterModel: ""
            ),
            Scenario(
                name: "claude-connected",
                selectedID: claudeID,
                connectedIDs: [claudeID],
                openRouterConnectingID: nil,
                statuses: [
                    BackendConfig.appleIntelligence.id: .ready("On this Mac"),
                    BackendConfig.chatGPT.id: .needsSetup("Continue with ChatGPT to connect your plan.", fix: .connectChatGPT),
                    "lmstudio": .needsSetup("LM Studio's server isn't running."),
                    openRouterID: .ready("anthropic/claude-sonnet-4.5"),
                    claudeID: .ready("Claude Sonnet 4.5"),
                ],
                claudeModel: "claude-sonnet-4-5",
                openRouterModel: "anthropic/claude-sonnet-4.5"
            ),
        ]

        for scenario in scenarios {
            var settings = AppSettings()
            var openRouter = BackendConfig.openAI(.openRouter, id: openRouterID)
            openRouter.openAI?.model = scenario.openRouterModel
            var claude = BackendConfig.anthropic(id: claudeID)
            claude.anthropic?.model = scenario.claudeModel
            settings.backends.append(contentsOf: [openRouter, claude])

            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("kandong-provider-preview-\(UUID())")
            let model = AppModel(previewSettings: settings, workspacePath: workspace.path)
            model.prepareProviderPreview(
                statuses: scenario.statuses,
                connectedIDs: scenario.connectedIDs,
                openRouterConnectingID: scenario.openRouterConnectingID,
                anthropicModels: claudeModels
            )
            let state = MainWindowState()
            state.tab = .ai
            state.backendID = scenario.selectedID

            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let dark = appearance == .darkAqua
                let view = MainView(model: model, state: state)
                    .frame(width: 820, height: 1040)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: appearance)
                host.frame = NSRect(x: 0, y: 0, width: 820, height: 1040)
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(300))
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
                let url = folder.appendingPathComponent("\(scenario.name)-\(dark ? "dark" : "light").png")
                try? png.write(to: url)
                print(url.path)
            }
            try? FileManager.default.removeItem(at: workspace)
        }
    }
}
#endif
