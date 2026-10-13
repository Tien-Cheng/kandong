import SwiftUI
import KandongKit

/// The AI section: which Backend answers Lookups, every Backend's status, and its settings.
struct AIBackendsView: View {
    @Bindable var model: AppModel
    @Binding var selectedID: String

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

            if let config = model.settings.backend(id: selectedID) {
                BackendDetail(model: model, config: binding(for: config)) { selectedID = BackendConfig.appleIntelligence.id }
                    .id(selectedID)
            }
        }
        .formStyle(.grouped)
        .task { if !model.isPreview { await model.refreshStatuses() } }
        .onChange(of: model.chatGPTConnecting, initial: true) {
            if model.chatGPTConnecting { selectedID = BackendConfig.chatGPT.id }
        }
        .sheet(isPresented: Binding(
            get: { model.chatGPTWelcomeAccountID != nil },
            set: { if !$0 { model.acknowledgeChatGPTWelcome(useByDefault: false) } }
        )) {
            VStack(alignment: .leading, spacing: 16) {
                Text("You're using your ChatGPT plan").font(.title2.bold())
                Text("Eligible AI requests in Kandong use your ChatGPT plan. You can review usage and manage Kandong's access in ChatGPT settings.")
                Link("Manage usage", destination: ChatGPTBackend.usageURL)
                Text("Your current default backend stays selected unless you choose ChatGPT.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Got it") { model.acknowledgeChatGPTWelcome(useByDefault: false) }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Use ChatGPT by default") { model.acknowledgeChatGPTWelcome(useByDefault: true) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(width: 440)
        }
    }

    /// Looks the Backend up by id on every access, so a removed one can't index past the list.
    private func binding(for config: BackendConfig) -> Binding<BackendConfig> {
        Binding(
            get: { model.settings.backend(id: config.id) ?? config },
            set: { updated in
                guard let index = model.settings.backends.firstIndex(where: { $0.id == config.id }) else { return }
                model.settings.backends[index] = updated
            }
        )
    }

    @ViewBuilder private func menu(for config: BackendConfig) -> some View {
        Button("Make Default") { model.settings.defaultBackendID = config.id }
            .disabled(model.settings.defaultBackendID == config.id)
        Button("Use for ⇧ (Local)") { model.settings.localBackendID = config.id }
            .disabled(!config.isOnDevice || model.settings.localBackendID == config.id)
        Button("Check Again") { Task { await model.refreshStatuses(only: config.id, clearChatGPTFailure: config.type == .chatGPT) } }
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
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    if let fix = model.statuses[config.id]?.fix, config.type != .chatGPT {
                        Button(model.title(for: fix)) { model.perform(fix) }
                    }
                    Button(testing ? "Testing…" : "Test", action: test)
                        .disabled(testing || (config.type == .chatGPT && !canTestChatGPT))
                }
            }
            switch config.type {
            case .appleIntelligence: EmptyView()
            case .chatGPT: ChatGPTFields(model: model)
            case .openAICompatible: OpenAIFields(model: model, config: $config)
            }
            Picker("Reading corrections", selection: $config.readingModeSetting) {
                Text("Recommended: " + config.defaultReadingMode.displayName).tag(ReadingMode?.none)
                Divider()
                ForEach(ReadingMode.allCases) { mode in Text(mode.displayName).tag(ReadingMode?.some(mode)) }
            }
            .help("Whether this Backend may change the dictionary's pinyin where a character has several readings (多音字).")
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

    private var canTestChatGPT: Bool {
        guard !model.chatGPTConnecting, !model.chatGPTSigningOut,
              let account = model.chatGPTAccounts.first(where: { $0.id == model.settings.chatGPT.accountID }) else { return false }
        return account.isSignedIn && account.hasPlanPermission
    }

    private var footer: String {
        switch config.type {
        case .appleIntelligence:
            "Apple's model on this Mac: nothing to install or sign in to, and text never leaves this Mac. Needs Apple Intelligence turned on in System Settings."
        case .chatGPT:
            "Use an eligible ChatGPT Plus or Pro plan. Text and any images you send go to OpenAI. No terminal setup or API key is needed."
        case .openAICompatible:
            switch config.preset {
            case .lmStudio?: "Runs fully on this Mac. Install LM Studio and start its server (Developer tab, or `lms server start`), then download the recommended model here. Thinking makes small models slow and can stall them, so Kandong translates with it off."
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
        let id = config.id
        Task {
            let started = Date()
            do {
                if config.type == .chatGPT, let id = model.settings.chatGPT.accountID {
                    await model.chatGPTBackendState.clear(accountID: id)
                }
                let reply = try await backend.complete(AIRequest(
                    system: "Translate to English. Reply with the translation only.", user: "你好，世界"
                ))
                testResult = "OK in \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(Prompts.visibleText(reply))"
            } catch {
                testResult = error.localizedDescription
            }
            await model.refreshStatuses(only: id)
            testing = false
        }
    }
}

private struct ChatGPTFields: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var models: [ChatGPTModel] = []
    @ViewState private var loadingModels = false
    @ViewState private var modelError = ""

    private var account: ChatGPTAccount? {
        model.chatGPTAccounts.first { $0.id == model.settings.chatGPT.accountID }
    }

    private var busy: Bool { model.chatGPTConnecting || model.chatGPTSigningOut }

    private var logo: NSImage? {
        let name = colorScheme == .dark ? "ChatGPTLogo" : "ChatGPTLogoWhite"
        return Bundle.kandongResources.url(forResource: name, withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    }

    var body: some View {
        if !model.chatGPTAccounts.isEmpty {
            Picker("ChatGPT account", selection: Binding(
                get: { model.settings.chatGPT.accountID ?? "" },
                set: { model.selectChatGPTAccount($0) }
            )) {
                if model.settings.chatGPT.accountID == nil { Text("Choose an account").tag("") }
                ForEach(model.chatGPTAccounts) { item in
                    Text(item.label + (item.isSignedIn ? "" : " (signed out)")).tag(item.id)
                }
            }
            .disabled(busy)
        }
        if model.chatGPTConnecting {
            LabeledContent("Sign-in") {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Continue in your browser…").foregroundStyle(.secondary)
                    Button("Cancel") { model.cancelChatGPTConnection() }
                }
            }
        } else if account?.isSignedIn != true {
            HStack {
                Button {
                    model.connectChatGPT(accountID: model.settings.chatGPT.accountID)
                } label: {
                    HStack(spacing: 8) {
                        if let logo {
                            Image(nsImage: logo).renderingMode(.original)
                                .resizable().frame(width: 21, height: 21)
                                .accessibilityHidden(true)
                        }
                        Text("Continue with ChatGPT").fontWeight(.medium)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(colorScheme == .dark ? .white : .black)
                .foregroundStyle(colorScheme == .dark ? .black : .white)
                .controlSize(.large)
                .disabled(busy)
                if account != nil {
                    Button("Add Account") { model.connectChatGPT() }.disabled(busy)
                }
            }
            if account != nil {
                Button("Clear Saved Credentials") { Task { await model.signOutChatGPT() } }.disabled(busy)
            }
        } else {
            LabeledContent("Connection") {
                Text(account?.hasPlanPermission == true ? "Using ChatGPT plan" : "Plan usage not enabled")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(account?.hasPlanPermission == true ? "Reconnect" : "Enable ChatGPT plan usage") {
                    model.connectChatGPT(accountID: model.settings.chatGPT.accountID)
                }
                Button("Add Account") { model.connectChatGPT() }
                Button(model.chatGPTSigningOut ? "Signing out…" : "Sign Out", role: .destructive) {
                    Task { await model.signOutChatGPT() }
                }
            }
            .disabled(busy)
        }
        if !model.chatGPTMessage.isEmpty {
            Text(model.chatGPTMessage).foregroundStyle(.secondary).textSelection(.enabled)
        }
        if account?.hasPlanPermission == true && account?.isSignedIn == true {
            Picker("Model", selection: $model.settings.chatGPT.model) {
                Text(loadingModels ? "Loading models…" : "First available model").tag("")
                ForEach(models) { Text($0.displayName).tag($0.id) }
                if !model.settings.chatGPT.model.isEmpty, !models.contains(where: { $0.id == model.settings.chatGPT.model }) {
                    Text(model.settings.chatGPT.model).tag(model.settings.chatGPT.model)
                }
            }
            .disabled(loadingModels || busy)
            if !modelError.isEmpty {
                Text(modelError).font(.caption).foregroundStyle(.secondary)
                Button("Reload Models") { Task { await refreshModels() } }.disabled(loadingModels || busy)
            }
            ThinkingPicker(title: "Thinking when translating", level: $model.settings.chatGPT.reasoning.translate,
                           options: [""] + Reasoning.openAILevels)
            ThinkingPicker(title: "Thinking when explaining", level: $model.settings.chatGPT.reasoning.explain,
                           options: [""] + Reasoning.openAILevels)
            Picker("Reads images", selection: $model.settings.chatGPT.vision) {
                Text("Detect (uses on-device OCR if unknown)").tag(VisionSupport.auto)
                Text("Yes").tag(VisionSupport.yes)
                Text("No, use on-device OCR").tag(VisionSupport.no)
            }
            if model.settings.defaultBackendID != BackendConfig.chatGPT.id {
                Button("Use ChatGPT by default") { model.settings.defaultBackendID = BackendConfig.chatGPT.id }
            }
        }
        HStack {
            Link("Manage usage", destination: ChatGPTBackend.usageURL)
            Button("Check Again") {
                Task { await model.refreshStatuses(only: BackendConfig.chatGPT.id, clearChatGPTFailure: true) }
            }
            .disabled(busy)
        }
            .task(id: model.settings.chatGPT.accountID) {
                await model.loadChatGPTAccounts()
                await refreshModels()
            }
            .onChange(of: model.chatGPTConnecting) {
                if !model.chatGPTConnecting { Task { await refreshModels() } }
            }
    }

    private func refreshModels() async {
        guard !model.isPreview else { return }
        let id = model.settings.chatGPT.accountID
        models = []
        modelError = ""
        guard account?.isSignedIn == true, account?.hasPlanPermission == true else { return }
        loadingModels = true
        defer { loadingModels = false }
        do {
            let backend = ChatGPTBackend(settings: model.settings.chatGPT, session: model.chatGPTSession, state: model.chatGPTBackendState)
            let result = try await backend.models()
            guard id == model.settings.chatGPT.accountID else { return }
            models = result
        } catch {
            guard id == model.settings.chatGPT.accountID else { return }
            modelError = error.localizedDescription
        }
    }
}

private struct OpenAIFields: View {
    @Bindable var model: AppModel
    @Binding var config: BackendConfig
    @ViewState private var lmModels: [LMStudioModel] = []
    @ViewState private var reachable = false
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
                    let id = config.id
                    Keychain.write(apiKey, for: config.keychainAccount)
                    Task { await model.refreshStatuses(only: id) }
                }
        }
        if config.isLMStudio {
            RecommendedModelRow(model: model, config: config, downloaded: lmModels.map(\.id), reachable: reachable,
                                inUse: settings.wrappedValue.model.isEmpty ? lmModels.first?.id : settings.wrappedValue.model)
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
        ThinkingPicker(title: "Thinking when translating", level: $config.reasoning.translate, options: thinkingOptions)
        ThinkingPicker(title: "Thinking when explaining", level: $config.reasoning.explain, options: thinkingOptions)
        if let thinkingNote {
            Text(thinkingNote).font(.caption).foregroundStyle(.secondary)
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
        // A finished download adds a model to LM Studio's list.
        .onChange(of: model.modelDownloads[config.id]?.isActive == true) { Task { await refresh() } }
    }

    /// The levels the chosen LM Studio model offers; any server's otherwise. nil when it can't think.
    private var thinkingOptions: [String]? {
        guard config.isLMStudio else { return [""] + Reasoning.openAILevels }
        let chosen = settings.wrappedValue.model.isEmpty ? lmModels.first : lmModels.first { $0.id == settings.wrappedValue.model }
        // Unknown (server down, or LM Studio before 0.4 doesn't say): offer every level.
        guard let chosen, let allowed = chosen.reasoningOptions else { return Reasoning.levels.filter { $0 != "on" } }
        return allowed.isEmpty ? nil : allowed
    }

    /// Says why the menu is short when the model can only switch thinking on or off.
    private var thinkingNote: String? {
        guard let options = thinkingOptions, Set(options) == ["off", "on"] else { return nil }
        let chosen = settings.wrappedValue.model.isEmpty ? lmModels.first?.id : settings.wrappedValue.model
        return "\(chosen ?? "This model") can only turn thinking on or off; it has no levels in between. Thinking makes it much slower."
    }

    private func refresh() async {
        let id = config.id, baseURL = settings.wrappedValue.baseURL, isLMStudio = config.isLMStudio
        if isLMStudio {
            let models = try? await LMStudio.models(baseURL: baseURL)
            lmModels = models ?? []
            reachable = models != nil
        }
        await model.refreshStatuses(only: id)
    }
}

/// How much a model thinks for one task. A model that can't think shows that instead of a menu; a level
/// the model doesn't offer is used as the nearest one below it.
private struct ThinkingPicker: View {
    let title: String
    @Binding var level: String
    /// nil when the model can't think.
    let options: [String]?

    var body: some View {
        if let options {
            let shown = options.contains(level) ? options : options + [level]
            Picker(title, selection: $level) {
                ForEach(shown, id: \.self) { option in
                    Text(Reasoning.displayName(option) + (options.contains(option) ? "" : " (uses \(Reasoning.displayName(Reasoning.resolve(option, allowed: options))))"))
                        .tag(option)
                }
            }
        } else {
            LabeledContent(title) { Text("This model doesn't think").foregroundStyle(.secondary) }
        }
    }
}

/// The model Kandong recommends for this Mac, with a button to download it into LM Studio.
private struct RecommendedModelRow: View {
    let model: AppModel
    let config: BackendConfig
    /// Models LM Studio already has.
    let downloaded: [String]
    let reachable: Bool
    /// The model the Backend answers with: the chosen one, or the first LM Studio has loaded.
    let inUse: String?

    var body: some View {
        let catalog = model.modelCatalog
        let memoryGB = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        let wanted = catalog.recommendation(memoryBytes: ProcessInfo.processInfo.physicalMemory, freeDiskBytes: nil)
        LabeledContent {
            // A download under way, or a model already here, needs no more disk.
            if let active = model.modelDownloads[config.id]?.modelID, let entry = catalog.models.first(where: { $0.id == active }) {
                content(for: entry)
            } else if let wanted, downloaded.contains(wanted.id) || inUse == wanted.id {
                content(for: wanted)
            } else if let recommended = catalog.recommendationForThisMac() {
                content(for: recommended)
            } else if let wanted {
                Text("Free up about \(Int(wanted.downloadGB.rounded(.up)) + 2) GB of disk to download \(wanted.name).")
                    .foregroundStyle(.secondary)
            } else {
                Text("Local models need 16 GB of memory to run well. Apple Intelligence is the better choice on this Mac.")
                    .foregroundStyle(.secondary)
            }
        } label: {
            Text("Recommended for this Mac")
            Text("\(memoryGB) GB memory")
        }
        .task { await model.loadModelCatalog() }
    }

    @ViewBuilder private func content(for recommended: RecommendedModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(recommended.name).foregroundStyle(.primary)
                    Text("About \(String(format: "%.1f", recommended.downloadGB)) GB · \(recommended.note)")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                action(for: recommended)
            }
            switch model.modelDownloads[config.id] {
            case .downloading(let id, let fraction, let detail)? where id == recommended.id:
                ProgressView(value: fraction) { EmptyView() } currentValueLabel: { Text(detail).font(.caption) }
            case .loading(let id)? where id == recommended.id:
                ProgressRowLabel(text: "Loading it into memory…")
            case .failed(let id, let message)? where id == recommended.id:
                Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder private func action(for recommended: RecommendedModel) -> some View {
        if case .downloading? = model.modelDownloads[config.id] {
            Button("Stop Watching") { model.stopWatchingDownload(for: config.id) }
                .help("Kandong stops following it; LM Studio carries on unless you stop it there.")
        } else if model.modelDownloads[config.id]?.isActive == true {
            EmptyView()
        } else if inUse == recommended.id {
            Label("In use", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
        } else if downloaded.contains(recommended.id) {
            Button("Use It") { model.useModel(recommended.id, for: config.id) }
        } else {
            Button(model.modelDownloads[config.id] == nil ? "Download" : "Try Again") { model.download(recommended, into: config.id) }
                .disabled(!reachable)
                .help(reachable ? "Downloads it in LM Studio" : "Start LM Studio's server first")
        }
    }
}

private struct ProgressRowLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}
