import SwiftUI
import KandongKit

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            backendSection
            CodexSection(model: model)
            OpenAISection(model: model, kind: .lmStudio)
            OpenAISection(model: model, kind: .custom)
            shortcutsSection
            learningSection
            workspaceSection
            PermissionsSection()
            historySection
        }
        .formStyle(.grouped)
    }

    private var backendSection: some View {
        Section {
            Picker("Default backend", selection: $model.settings.defaultBackend) {
                ForEach(BackendKind.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Local backend (hold ⇧)", selection: $model.settings.localBackend) {
                ForEach(BackendKind.localCandidates) { Text($0.displayName).tag($0) }
            }
        } header: {
            Text("AI")
        } footer: {
            Text("Hold ⇧ with any shortcut to send that lookup to the Local backend instead — e.g. for private messages you'd rather keep on this Mac.")
        }
    }

    private var shortcutsSection: some View {
        Section {
            Picker("Tap alone to look up the selection", selection: $model.settings.tapKey) {
                ForEach(TapKey.allCases) { Text($0.displayName).tag($0) }
            }
            ForEach(HotkeyAction.allCases) { action in
                LabeledContent(action.displayName) {
                    ShortcutRecorder(model: model, combo: Binding(
                        get: { model.settings.hotkeys[action] ?? AppSettings.defaultHotkeys[action]! },
                        set: { model.settings.hotkeys[action] = $0 }
                    ))
                }
            }
            Button("Restore default shortcuts") { model.settings.hotkeys = AppSettings.defaultHotkeys }
        } header: {
            Text("Shortcuts")
        } footer: {
            Text("Add ⇧ to any shortcut (or hold ⇧ while tapping the tap key) to use the Local backend. Pick a tap key your other tools don't use — dictation apps often take right ⌥.")
        }
    }

    private var learningSection: some View {
        Section("Learning") {
            Picker("My level", selection: $model.settings.myLevel) {
                Text("Off — show everything").tag(0)
                ForEach(1...7, id: \.self) { Text(HSKTable.label(for: $0)).tag($0) }
            }
            Toggle("Pinyin only for words above my level", isOn: $model.settings.pinyinForUnknownOnly)
                .disabled(model.settings.myLevel == 0)
            Toggle("Always explain (uses more AI quota)", isOn: $model.settings.alwaysExplain)
        }
    }

    private var workspaceSection: some View {
        Section {
            LabeledContent("Folder") {
                HStack {
                    TextField("", text: $model.settings.workspacePath).labelsHidden()
                    Button("Choose…", action: chooseFolder)
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([model.workspace.contextURL]) }
                }
            }
            HStack {
                Button("Edit context.md") { NSWorkspace.shared.open(model.workspace.contextURL) }
                Button("Edit terms.csv") { NSWorkspace.shared.open(model.workspace.termsURL) }
            }
        } header: {
            Text("Workspace")
        } footer: {
            Text("context.md describes you and your domain; terms.csv fixes translations; vocabulary.csv holds saved words. Plain files, so agents can edit them — changes apply to the next lookup.")
        }
    }

    private var historySection: some View {
        Section("History") {
            Stepper("Keep history for \(model.settings.historyRetentionDays) days",
                    value: $model.settings.historyRetentionDays, in: 7...3650, step: 30)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.workspacePath = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}

// MARK: - Codex

private struct CodexSection: View {
    @Bindable var model: AppModel
    @ViewState private var models: [CodexModel] = []
    @ViewState private var status = ""
    @ViewState private var testing = false

    var body: some View {
        Section {
            LabeledContent("Status") {
                HStack {
                    Text(status).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button(testing ? "Testing…" : "Test", action: test).disabled(testing)
                }
            }
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
        } header: {
            Text("Codex")
        } footer: {
            Text("Uses your ChatGPT subscription through the Codex CLI (`codex app-server`). Sign in with `codex login`. Lower effort answers faster.")
        }
        .task { await refresh() }
    }

    private var effortOptions: [String] {
        let fromModel = models.first { $0.id == model.settings.codex.model }?.reasoningEfforts ?? []
        let options = fromModel.isEmpty ? ["minimal", "low", "medium", "high"] : fromModel
        return options.contains(model.settings.codex.effort) ? options : options + [model.settings.codex.effort]
    }

    private func refresh() async {
        guard let path = CodexAppServer.locateCodex(model.settings.codex.executablePath) else {
            status = "codex not found — `brew install codex`"
            return
        }
        do {
            models = try await CodexAppServer.shared.models(executablePath: model.settings.codex.executablePath)
            status = "Ready · \(path.path)"
        } catch {
            status = error.localizedDescription
        }
    }

    private func test() {
        testing = true
        Task {
            let started = Date()
            do {
                let reply = try await model.backend(for: .codex).complete(AIRequest(
                    system: "Translate to English. Reply with the translation only.", user: "你好，世界"
                ))
                status = "OK in \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(reply)"
            } catch {
                status = error.localizedDescription
            }
            testing = false
        }
    }
}

// MARK: - LM Studio / custom endpoint

private struct OpenAISection: View {
    @Bindable var model: AppModel
    let kind: BackendKind
    @ViewState private var lmModels: [LMStudioModel] = []
    @ViewState private var status = ""
    @ViewState private var apiKey = ""
    @ViewState private var testing = false

    private var settings: Binding<OpenAISettings> {
        kind == .lmStudio ? $model.settings.lmStudio : $model.settings.custom
    }

    var body: some View {
        Section {
            TextField("Server URL", text: settings.baseURL)
            if kind == .custom {
                SecureField("API key (optional)", text: $apiKey)
                    .onSubmit { Keychain.write(apiKey, for: AppModel.customKeyAccount) }
                    .onChange(of: apiKey) { Keychain.write(apiKey, for: AppModel.customKeyAccount) }
            }
            if kind == .lmStudio && !lmModels.isEmpty {
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
                Text(kind == .lmStudio ? "Detect (vision models)" : "Auto (no)").tag(VisionSupport.auto)
                Text("Yes").tag(VisionSupport.yes)
                Text("No — use on-device OCR").tag(VisionSupport.no)
            }
            LabeledContent("Status") {
                HStack {
                    Text(status).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    if kind == .lmStudio { Button("Refresh") { Task { await refresh() } } }
                    Button(testing ? "Testing…" : "Test", action: test).disabled(testing)
                }
            }
        } header: {
            Text(kind == .lmStudio ? "LM Studio" : "Other OpenAI-compatible server")
        } footer: {
            Text(kind == .lmStudio
                 ? "Runs fully on this Mac. In LM Studio, download a model (Qwen3 handles Chinese well; pick a vision model to read screenshots) and start the server: Developer tab or `lms server start`."
                 : "Ollama (http://localhost:11434/v1), or any hosted OpenAI-compatible API. The key is stored in your Keychain.")
        }
        .task {
            if kind == .custom { apiKey = Keychain.read(AppModel.customKeyAccount) ?? "" }
            if kind == .lmStudio { await refresh() }
        }
    }

    private func refresh() async {
        do {
            lmModels = try await LMStudio.models(baseURL: settings.wrappedValue.baseURL)
            let loaded = lmModels.filter(\.isLoaded).count
            status = lmModels.isEmpty ? "Running, but no models downloaded." : "Running · \(lmModels.count) models (\(loaded) loaded)"
        } catch {
            lmModels = []
            status = error.localizedDescription
        }
    }

    private func test() {
        testing = true
        Task {
            let started = Date()
            do {
                let reply = try await model.backend(for: kind).complete(AIRequest(
                    system: "Translate to English. Reply with the translation only.", user: "你好，世界"
                ))
                status = "OK in \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(Prompts.visibleText(reply))"
            } catch {
                status = error.localizedDescription
            }
            testing = false
        }
    }
}

// MARK: - Permissions

private struct PermissionsSection: View {
    @ViewState private var accessibility = Permissions.accessibilityGranted
    @ViewState private var screenRecording = Permissions.screenRecordingGranted

    var body: some View {
        Section {
            LabeledContent("Accessibility") {
                HStack {
                    Text(accessibility ? "Granted" : "Needed to read selected text and the tap key")
                        .foregroundStyle(accessibility ? .green : .orange)
                    if !accessibility {
                        Button("Open Settings") {
                            Permissions.requestAccessibility()
                            Permissions.openPrivacyPane("Privacy_Accessibility")
                        }
                    }
                }
            }
            LabeledContent("Screen Recording") {
                HStack {
                    Text(screenRecording ? "Granted" : "Needed for screen region capture")
                        .foregroundStyle(screenRecording ? .green : .orange)
                    if !screenRecording {
                        Button("Open Settings") {
                            Permissions.requestScreenRecording()
                            Permissions.openPrivacyPane("Privacy_ScreenCapture")
                        }
                    }
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("After granting a permission you may need to quit and reopen Kandong.")
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            accessibility = Permissions.accessibilityGranted
            screenRecording = Permissions.screenRecordingGranted
        }
    }
}

// MARK: - Shortcut recorder

private struct ShortcutRecorder: View {
    let model: AppModel
    @Binding var combo: KeyCombo
    @ViewState private var recording = false
    @ViewState private var monitor: Any?

    var body: some View {
        Button(recording ? "Press shortcut… (⎋ cancels)" : combo.displayString) {
            recording ? stop() : start()
        }
        .monospaced()
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        model.suspendHotkeys(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stop()
                return nil
            }
            let candidate = KeyCombo(event: event)
            guard candidate.command || candidate.control || candidate.option else {
                NSSound.beep()
                return nil
            }
            combo = candidate
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            model.suspendHotkeys(false)
        }
    }
}
