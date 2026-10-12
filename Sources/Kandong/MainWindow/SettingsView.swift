import SwiftUI
import KandongKit

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            shortcutsSection
            learningSection
            workspaceSection
            PermissionsSection()
            historySection
        }
        .formStyle(.grouped)
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
        Section {
            Picker("My level", selection: $model.settings.myLevel) {
                Text("Off — show everything").tag(0)
                ForEach(1...7, id: \.self) { Text(HSKTable.label(for: $0)).tag($0) }
            }
            Toggle("Pinyin only for words above my level", isOn: $model.settings.pinyinForUnknownOnly)
                .disabled(model.settings.myLevel == 0)
            Toggle("Always explain (uses more AI quota)", isOn: $model.settings.alwaysExplain)
        } header: {
            Text("Learning")
        } footer: {
            Text("Words at or below your HSK level are folded away in the word list, so new words stand out.")
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
        Section {
            Stepper("Keep history for \(model.settings.historyRetentionDays) days",
                    value: $model.settings.historyRetentionDays, in: 7...3650, step: 30)
        } header: {
            Text("History")
        } footer: {
            Text("Lookups and how often you meet saved words are kept on this Mac only.")
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
