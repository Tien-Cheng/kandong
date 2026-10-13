import SwiftUI
import KandongKit

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            shortcutsSection
            learningSection
            workspaceSection
            dictionariesSection
            PermissionsSection()
            historySection
            if let updater = AppDelegate.shared?.updater {
                UpdatesSection(updater: updater)
            }
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
            Picker("My level", selection: Binding(get: { model.settings.myLevel }, set: {
                model.settings.myLevel = $0
                model.settings.hasChosenLevel = true
            })) {
                Text("Off — show everything").tag(0)
                ForEach(1...7, id: \.self) { Text(HSKTable.label(for: $0)).tag($0) }
            }
            Toggle("Pinyin only for words above my level", isOn: $model.settings.pinyinForUnknownOnly)
                .disabled(model.settings.myLevel == 0)
            Picker("Chinese typeface", selection: $model.settings.readingTypeface) {
                ForEach(ReadingTypeface.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle("Always explain", isOn: $model.settings.alwaysExplain)
        } header: {
            Text("Learning")
        } footer: {
            Text("Words at or below your HSK level are folded away in the word list, so new words stand out. LXGW WenKai is a clear regular-script face that shows each stroke; PingFang is what most apps use. Always explain asks the AI for more with every Lookup, which is slower and, on hosted Backends, uses more quota.")
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

    private var dictionariesSection: some View {
        Section {
            LabeledContent("CC-CEDICT") { Text("Built in").foregroundStyle(.secondary) }
            ForEach(model.addOns) { addOn in
                LabeledContent {
                    HStack {
                        Text("\(addOn.entryCount.formatted()) words" + (addOn.updated.isEmpty ? "" : " · \(addOn.updated)"))
                            .foregroundStyle(.secondary)
                        if addOn.id == ETOGlossary.id {
                            Button("Update", action: model.downloadTechnicalTerms).disabled(model.addOnStatus == .working)
                        }
                        Button("Remove") { model.removeAddOn(addOn) }
                            .disabled(addOn.id == ETOGlossary.id && model.addOnStatus == .working)
                    }
                } label: {
                    Text(addOn.name)
                    if !addOn.license.isEmpty { Text(addOn.license) }
                }
            }
            if !model.addOns.contains(where: { $0.id == ETOGlossary.id }) {
                LabeledContent {
                    Button(model.addOnStatus == .working ? "Downloading…" : "Download", action: model.downloadTechnicalTerms)
                        .disabled(model.addOnStatus == .working)
                } label: {
                    Text("Technical terms")
                    Text("About 15,000 AI, chip and science terms from the CSET-ETO Chinese Technical Glossary (glossary.eto.tech). CC BY-NC 4.0: for non-commercial use.")
                }
            }
            if case .failed(let message)? = model.addOnStatus {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Dictionaries")
                // Pick up files added to the folder since the last load.
                .task { model.reloadDictionariesIfChanged() }
        } footer: {
            HStack(alignment: .firstTextBaseline) {
                Text("Add-on dictionaries add words CC-CEDICT doesn't have, like 多模态 (multimodal). They're CC-CEDICT-format files in the Workspace's dictionaries folder; add your own there.")
                Button("Show Folder") {
                    try? FileManager.default.createDirectory(at: model.workspace.dictionariesURL, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(model.workspace.dictionariesURL)
                }
                .buttonStyle(.link)
            }
        }
    }

    private var historySection: some View {
        Section {
            Picker("Keep history for", selection: $model.settings.historyRetentionDays) {
                ForEach(Self.retentionChoices(including: model.settings.historyRetentionDays), id: \.self) { days in
                    Text(Self.retentionLabel(days)).tag(days)
                }
            }
        } header: {
            Text("History")
        } footer: {
            Text("Lookups and how often you meet saved words are kept on this Mac only.")
        }
    }

    private static func retentionChoices(including current: Int) -> [Int] {
        Array(Set([7, 30, 90, 180, 365, 730, 3650, current])).sorted()
    }

    private static func retentionLabel(_ days: Int) -> String {
        switch days {
        case 7: "1 week"
        case 30: "1 month"
        case 365: "1 year"
        case 730: "2 years"
        case 3650: "10 years"
        default: days % 30 == 0 ? "\(days / 30) months" : "\(days) days"
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

/// Sparkle's settings, kept in Kandong's user defaults by Sparkle itself.
private struct UpdatesSection: View {
    @Bindable var updater: Updater

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
            Toggle("Download and install updates automatically", isOn: $updater.automaticallyDownloads)
                .disabled(!updater.automaticallyChecks)
            LabeledContent("Version \(updater.currentVersion)") {
                Button("Check Now") { updater.checkForUpdates() }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Kandong checks GitHub for a new version once a day and sends nothing about your Mac. A downloaded update installs when Kandong quits, or straight away from Restart to Update in the menu bar.")
        }
    }
}
