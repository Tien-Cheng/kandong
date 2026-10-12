import SwiftUI
import KandongKit

/// The AI section: which Backend answers Lookups, every Backend's status, and its settings.
struct AIBackendsView: View {
    @Bindable var model: AppModel
    @ViewState private var selectedID = BackendConfig.appleIntelligence.id

    var body: some View {
        Form {
            Section {
                Picker("Default backend", selection: $model.settings.defaultBackendID) {
                    ForEach(model.settings.backends) { Text($0.name).tag($0.id) }
                }
                Picker("Local backend (hold ⇧)", selection: $model.settings.localBackendID) {
                    ForEach(model.settings.localCandidates) { Text($0.name).tag($0.id) }
                }
            } footer: {
                Text("Hold ⇧ with any shortcut to use the Local backend instead — for private messages you'd rather keep on this Mac. Only Backends that run on this Mac can be the Local one.")
            }

            Section {
                ForEach(model.settings.backends) { config in
                    BackendRow(model: model, config: config, isSelected: config.id == selectedID)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedID = config.id }
                        .contextMenu { menu(for: config) }
                }
                Menu("Add Backend") {
                    ForEach(OpenAIPreset.allCases) { preset in
                        Button(preset.displayName) { selectedID = model.addBackend(preset).id }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } header: {
                Text("Backends")
            } footer: {
                Text("Add Ollama, OpenRouter, OpenAI or any OpenAI-compatible server. Right-click a Backend to make it the default.")
            }

            if let index = model.settings.backends.firstIndex(where: { $0.id == selectedID }) {
                BackendDetail(model: model, config: $model.settings.backends[index]) { selectedID = BackendConfig.appleIntelligence.id }
                    .id(selectedID)
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshStatuses() }
    }

    @ViewBuilder private func menu(for config: BackendConfig) -> some View {
        Button("Make Default") { model.settings.defaultBackendID = config.id }
            .disabled(model.settings.defaultBackendID == config.id)
        Button("Use for ⇧ (Local)") { model.settings.localBackendID = config.id }
            .disabled(!config.isOnDevice || model.settings.localBackendID == config.id)
        Button("Check Again") { Task { await model.refreshStatuses(only: config.id) } }
        if !config.isBuiltIn {
            Divider()
            Button("Remove", role: .destructive) { model.removeBackend(config) }
        }
    }
}

private struct BackendRow: View {
    let model: AppModel
    let config: BackendConfig
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: model.statuses[config.id])
            VStack(alignment: .leading, spacing: 1) {
                Text(config.name).fontWeight(isSelected ? .semibold : .regular)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.settings.defaultBackendID == config.id { Chip("Default", color: .accentColor) }
            if model.settings.localBackendID == config.id { Chip("⇧ Local", color: .green) }
            Image(systemName: config.isOnDevice ? "desktopcomputer" : "cloud")
                .foregroundStyle(.secondary)
                .help(config.isOnDevice ? "Text stays on this Mac" : "Text is sent over the internet")
        }
        .padding(.vertical, 2)
        .background(isSelected ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private var detail: String {
        switch model.statuses[config.id] {
        case nil: "Checking…"
        case .ready(let message): message.isEmpty ? "Ready" : message
        case let status?: status.message
        }
    }
}

struct StatusDot: View {
    let status: BackendStatus?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help(status?.message ?? "Checking…")
    }

    private var color: Color {
        switch status {
        case .ready?: .green
        case .needsSetup?: .orange
        case .unavailable?: .red
        case nil: .gray.opacity(0.5)
        }
    }
}

struct Chip: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color = .gray) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
    }
}

// MARK: - Detail

private struct BackendDetail: View {
    @Bindable var model: AppModel
    @Binding var config: BackendConfig
    let onRemove: () -> Void
    @ViewState private var testResult = ""
    @ViewState private var testing = false

    var body: some View {
        Section {
            LabeledContent("Status") {
                HStack {
                    Text(testResult.isEmpty ? (model.statuses[config.id]?.message ?? "Checking…") : testResult)
                        .foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    Spacer()
                    if let fix = model.statuses[config.id]?.fix {
                        Button(fix.label) { model.perform(fix) }
                    }
                    Button(testing ? "Testing…" : "Test", action: test).disabled(testing)
                }
            }
            switch config.type {
            case .appleIntelligence: EmptyView()
            case .codex: CodexFields(model: model)
            case .openAICompatible: OpenAIFields(model: model, config: $config)
            }
            if !config.isBuiltIn {
                Button("Remove \(config.name)", role: .destructive) {
                    model.removeBackend(config)
                    onRemove()
                }
            }
        } header: {
            Text(config.name)
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        switch config.type {
        case .appleIntelligence:
            "Apple's model on this Mac: nothing to install or sign in to, and text never leaves this Mac. Needs Apple Intelligence turned on in System Settings."
        case .codex:
            "Uses your ChatGPT subscription through the Codex CLI (`codex app-server`). Sign in with `codex login`. Lower effort answers faster."
        case .openAICompatible:
            switch config.preset {
            case .lmStudio?: "Runs fully on this Mac. In LM Studio, download a model and start the server: Developer tab, or `lms server start`. Pick a vision model to read screenshots."
            case .ollama?: "Runs fully on this Mac. Install Ollama, then `ollama pull` a model."
            case .openRouter?, .openAI?: "A hosted service: text is sent to it. The key is stored in your Keychain."
            default: "Any server speaking OpenAI's chat completions API. A key, if needed, is stored in your Keychain."
            }
        }
    }

    private func test() {
        testing = true
        testResult = ""
        let backend = model.backend(for: config)
        Task {
            let started = Date()
            do {
                let reply = try await backend.complete(AIRequest(
                    system: "Translate to English. Reply with the translation only.", user: "你好，世界"
                ))
                testResult = "OK in \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(Prompts.visibleText(reply))"
            } catch {
                testResult = error.localizedDescription
            }
            await model.refreshStatuses(only: config.id)
            testing = false
        }
    }
}

private struct CodexFields: View {
    @Bindable var model: AppModel
    @ViewState private var models: [CodexModel] = []

    var body: some View {
        Picker("Model", selection: $model.settings.codex.model) {
            Text("Codex default").tag("")
            ForEach(models) { Text($0.displayName + ($0.canReadImages ? "" : " (text only)")).tag($0.id) }
            if !model.settings.codex.model.isEmpty, !models.contains(where: { $0.id == model.settings.codex.model }) {
                Text(model.settings.codex.model).tag(model.settings.codex.model)
            }
        }
        Picker("Reasoning effort", selection: $model.settings.codex.effort) {
            ForEach(effortOptions, id: \.self) { Text($0).tag($0) }
        }
        TextField("codex path", text: $model.settings.codex.executablePath, prompt: Text("Found automatically"))
            .task { models = (try? await CodexAppServer.shared.models(executablePath: model.settings.codex.executablePath)) ?? [] }
    }

    private var effortOptions: [String] {
        let fromModel = models.first { $0.id == model.settings.codex.model }?.reasoningEfforts ?? []
        let options = fromModel.isEmpty ? ["minimal", "low", "medium", "high"] : fromModel
        return options.contains(model.settings.codex.effort) ? options : options + [model.settings.codex.effort]
    }
}

private struct OpenAIFields: View {
    @Bindable var model: AppModel
    @Binding var config: BackendConfig
    @ViewState private var lmModels: [LMStudioModel] = []
    @ViewState private var apiKey = ""

    private var settings: Binding<OpenAISettings> {
        Binding(
            get: { config.openAI ?? OpenAISettings(baseURL: (config.preset ?? .other).baseURL) },
            set: { config.openAI = $0 }
        )
    }

    var body: some View {
        TextField("Name", text: $config.name)
        TextField("Server URL", text: settings.baseURL)
            .onSubmit { Task { await refresh() } }
        if config.preset != .lmStudio && config.preset != .ollama {
            SecureField(config.preset?.needsKey == true ? "API key" : "API key (optional)", text: $apiKey)
                .onChange(of: apiKey) {
                    Keychain.write(apiKey, for: config.keychainAccount)
                    Task { await model.refreshStatuses(only: config.id) }
                }
        }
        if config.isLMStudio && !lmModels.isEmpty {
            Picker("Model", selection: settings.model) {
                Text("First loaded model").tag("")
                ForEach(lmModels) { item in
                    Text(item.id + (item.canReadImages ? " · vision" : "") + (item.isLoaded ? " · loaded" : "")).tag(item.id)
                }
                if !settings.wrappedValue.model.isEmpty, !lmModels.contains(where: { $0.id == settings.wrappedValue.model }) {
                    Text(settings.wrappedValue.model).tag(settings.wrappedValue.model)
                }
            }
        } else {
            TextField("Model", text: settings.model, prompt: Text("First model the server lists"))
        }
        Picker("Reads images", selection: settings.vision) {
            Text(config.isLMStudio ? "Detect (vision models)" : "Auto (no)").tag(VisionSupport.auto)
            Text("Yes").tag(VisionSupport.yes)
            Text("No — use on-device OCR").tag(VisionSupport.no)
        }
        .task {
            apiKey = Keychain.read(config.keychainAccount) ?? ""
            await refresh()
        }
    }

    private func refresh() async {
        if config.isLMStudio { lmModels = (try? await LMStudio.models(baseURL: settings.wrappedValue.baseURL)) ?? [] }
        await model.refreshStatuses(only: config.id)
    }
}
