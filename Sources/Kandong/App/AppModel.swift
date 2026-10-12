import AppKit
import Observation
import OSLog
import KandongKit

let lookupLog = Logger(subsystem: "com.tiencheng.kandong", category: "lookup")

/// App-wide state and the Lookup flow.
@MainActor
@Observable
final class AppModel {

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            saveSettings()
            applySettings(previous: oldValue)
        }
    }

    private(set) var workspace: Workspace
    /// Bumped whenever Workspace files change, so views re-read them.
    private(set) var workspaceRevision = 0
    private(set) var engine: LookupEngine?
    private(set) var dictionaryError: String?
    let history: HistoryStore
    var session: LookupSession?
    /// Last known readiness of each Backend, by id.
    private(set) var statuses: [String: BackendStatus] = [:]

    @ObservationIgnored private var analyzerTask: Task<OfflineAnalyzer?, Never>?
    @ObservationIgnored private var hotkeys: HotkeyCenter!
    @ObservationIgnored private var tapMonitor: ModifierTapMonitor!
    @ObservationIgnored lazy var panel = ResultPanelController(model: self)

    init() {
        let stored = UserDefaults.standard.data(forKey: "settings").flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
        settings = stored ?? AppSettings()
        workspace = Workspace(path: (stored ?? AppSettings()).workspacePath)
        history = (try? HistoryStore(url: HistoryStore.defaultURL)) ?? (try! HistoryStore.inMemory())

        Self.moveLegacyKeychainAccounts()
        hotkeys = HotkeyCenter { [weak self] action, local in self?.perform(action, local: local) }
        tapMonitor = ModifierTapMonitor { [weak self] local in self?.perform(.lookupSelection, local: local) }
        applySettings(previous: nil)
        history.prune(olderThanDays: settings.historyRetentionDays)
        loadDictionary()
    }

    // MARK: Settings

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "settings") }
    }

    private func applySettings(previous: AppSettings?) {
        if previous?.hotkeys != settings.hotkeys || previous == nil { hotkeys.register(settings.hotkeys) }
        tapMonitor.key = settings.tapKey
        if previous == nil || previous?.workspacePath != settings.workspacePath { openWorkspace() }
        if previous?.codex.executablePath != settings.codex.executablePath {
            Task { await CodexAppServer.shared.stop() }
        }
    }

    /// Lets the shortcut recorder capture keys that are currently registered.
    func suspendHotkeys(_ suspended: Bool) {
        suspended ? hotkeys.unregisterAll() : hotkeys.register(settings.hotkeys)
    }

    private func openWorkspace() {
        workspace.stopWatching()
        workspace = Workspace(path: settings.workspacePath)
        try? workspace.ensureExists()
        if let engine { self.engine = LookupEngine(analyzer: engine.analyzer, workspace: workspace) }
        workspace.watch { [weak self] in
            MainActor.assumeIsolated { self?.workspaceRevision += 1 }
        }
        workspaceRevision += 1
    }

    func workspaceDidChange() {
        workspaceRevision += 1
    }

    // MARK: Dictionary

    static var dataDirectory: URL {
        if let resources = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resources.appendingPathComponent("cedict_ts.u8").path) {
            return resources
        }
        // Running from `swift run`: use the repo's Data folder.
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Data")
    }

    private func loadDictionary() {
        let directory = Self.dataDirectory
        let task = Task.detached(priority: .userInitiated) { () -> OfflineAnalyzer? in
            guard let dict = try? CEDict(contentsOf: directory.appendingPathComponent("cedict_ts.u8")) else { return nil }
            let hsk = (try? HSKTable(contentsOf: directory.appendingPathComponent("hsk.tsv"))) ?? HSKTable()
            return OfflineAnalyzer(dictionary: dict, hsk: hsk)
        }
        analyzerTask = task
        Task {
            if let analyzer = await task.value {
                engine = LookupEngine(analyzer: analyzer, workspace: workspace)
            } else {
                dictionaryError = "Dictionary data missing in \(directory.path). Run scripts/fetch-data.sh and rebuild."
            }
        }
    }

    private func readyEngine() async -> LookupEngine? {
        if let engine { return engine }
        guard let analyzer = await analyzerTask?.value else { return nil }
        if engine == nil { engine = LookupEngine(analyzer: analyzer, workspace: workspace) }
        return engine
    }

    // MARK: Backends

    func backend(for config: BackendConfig) -> AIBackend {
        switch config.type {
        case .appleIntelligence: AppleIntelligenceBackend()
        case .codex: CodexBackend(settings: settings.codex)
        case .openAICompatible: OpenAICompatibleBackend(config: config, apiKey: Keychain.read(config.keychainAccount))
        }
    }

    /// Checks every Backend (or one) and remembers whether it can answer.
    func refreshStatuses(only id: String? = nil) async {
        let configs = settings.backends.filter { id == nil || $0.id == id }
        await withTaskGroup(of: (String, BackendStatus).self) { group in
            for config in configs {
                let backend = backend(for: config)
                group.addTask { (config.id, await backend.status()) }
            }
            for await (id, status) in group { statuses[id] = status }
        }
    }

    func addBackend(_ preset: OpenAIPreset) -> BackendConfig {
        let config = BackendConfig.openAI(preset)
        settings.backends.append(config)
        return config
    }

    func removeBackend(_ config: BackendConfig) {
        Keychain.write("", for: config.keychainAccount)
        settings.removeBackend(id: config.id)
        statuses[config.id] = nil
    }

    /// Does what a Backend's status suggests to make it ready.
    func perform(_ fix: FixAction) {
        switch fix {
        case .openURL(let url, _):
            NSWorkspace.shared.open(url)
        case .copyCommand(let command, _):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                NSWorkspace.shared.openApplication(at: terminal, configuration: NSWorkspace.OpenConfiguration())
            }
        case .openApp(let bundleID, _):
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            await refreshStatuses()
        }
    }

    private static func moveLegacyKeychainAccounts() {
        for (old, new) in legacyKeychainAccounts {
            guard Keychain.read(new) == nil, let key = Keychain.read(old) else { continue }
            Keychain.write(key, for: new)
            Keychain.write("", for: old)
        }
    }

    // MARK: Lookups

    func perform(_ action: HotkeyAction, local: Bool) {
        let config = settings.backend(local: local)
        switch action {
        case .lookupSelection: lookupSelection(config: config)
        case .captureScreen: captureScreen(config: config)
        case .lookupClipboard: lookupClipboard(config: config)
        }
    }

    private func lookupSelection(config: BackendConfig) {
        Task {
            let anchor = NSEvent.mouseLocation
            guard Permissions.accessibilityGranted else {
                Permissions.requestAccessibility()
                showMessage("Kandong needs Accessibility access to read selected text. Enable it in System Settings → Privacy & Security → Accessibility, then try again.", source: .selection, anchor: anchor)
                return
            }
            guard let selection = await SelectionReader.read() else {
                showMessage("No selection — highlight some text first.", source: .selection, anchor: anchor)
                return
            }
            lookup(text: selection.text, source: .selection, config: config, anchor: selection.bounds ?? CGRect(origin: anchor, size: .zero))
        }
    }

    private func captureScreen(config: BackendConfig) {
        Task {
            guard let image = await ScreenCapture.captureRegion() else { return }
            lookup(image: image, source: .screenCapture, config: config, anchor: CGRect(origin: NSEvent.mouseLocation, size: .zero))
        }
    }

    private func lookupClipboard(config: BackendConfig) {
        let anchor = CGRect(origin: NSEvent.mouseLocation, size: .zero)
        switch ClipboardReader.read() {
        case .image(let data): lookup(image: data, source: .clipboard, config: config, anchor: anchor)
        case .text(let text): lookup(text: text, source: .clipboard, config: config, anchor: anchor)
        case nil: showMessage("The clipboard has no text or image.", source: .clipboard, anchor: anchor.origin)
        }
    }

    private func startSession(source: LookupSource, config: BackendConfig) -> LookupSession {
        session?.cancel()
        let session = LookupSession(source: source)
        if config.type == .appleIntelligence { AppleIntelligenceBackend.prewarm() }
        session.backendID = config.id
        session.backendLabel = backend(for: config).label
        session.backendIsLocal = config.isOnDevice
        self.session = session
        return session
    }

    private func showMessage(_ message: String, source: LookupSource, anchor: CGPoint) {
        let session = startSession(source: source, config: settings.backend(local: false))
        session.message = message
        session.status = .done
        panel.show(near: CGRect(origin: anchor, size: .zero))
    }

    private func lookup(image: Data, source: LookupSource, config: BackendConfig, anchor: CGRect) {
        let session = startSession(source: source, config: config)
        session.status = .readingImage
        panel.show(near: anchor)
        let backend = backend(for: config)
        session.tasks.append(Task {
            let png = ImageData.normalized(image)
            // On-device OCR runs alongside as the fallback and as a check on the model's reading order.
            let ocrTask = Task.detached(priority: .userInitiated) { (try? await OCR.recognize(png)) ?? "" }
            var text = ""
            // Vision-capable Backend reads the image; otherwise (or if that fails) Apple's on-device OCR.
            if await backend.supportsImages(), let engine = await readyEngine() {
                do {
                    text = try await engine.transcribe(image: png, backend: backend)
                } catch {
                    lookupLog.error("transcription failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            // When the model already read the image, don't hold the Lookup up for a slow OCR pass.
            let ocrText = text.isEmpty ? await ocrTask.value : (await Self.value(of: ocrTask, within: .milliseconds(1500)) ?? "")
            lookupLog.debug("image read: model \(text.count) chars, OCR \(ocrText.count) chars")
            text = Self.preferredTranscription(model: text, ocr: ocrText)
            guard !Task.isCancelled, self.session === session else { return }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                session.message = "No text found in the image."
                session.status = .done
                return
            }
            run(session, text: text, config: config)
        })
    }

    /// The model's transcription, unless it is empty or merely reorders the same characters OCR read
    /// (vision models occasionally shuffle a line; OCR keeps the true order).
    static func preferredTranscription(model: String, ocr: String) -> String {
        let modelText = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let ocrText = ocr.trimmingCharacters(in: .whitespacesAndNewlines)
        if modelText.isEmpty { return ocrText }
        let significant: (String) -> [Character] = { $0.filter { !$0.isWhitespace }.sorted() }
        if !ocrText.isEmpty, significant(modelText) == significant(ocrText), modelText != ocrText { return ocrText }
        return modelText
    }

    /// The task's value if it finishes within `timeout`, else nil (the task keeps running).
    static func value<T: Sendable>(of task: Task<T, Never>, within timeout: Duration) async -> T? {
        let once = ResumeOnce<T?>()
        return await withCheckedContinuation { continuation in
            Task { once.resume(continuation, with: await task.value) }
            Task {
                try? await Task.sleep(for: timeout)
                once.resume(continuation, with: nil)
            }
        }
    }

    func lookup(text: String, source: LookupSource, local: Bool, anchor: CGRect? = nil) {
        lookup(text: text, source: source, config: settings.backend(local: local), anchor: anchor)
    }

    func lookup(text: String, source: LookupSource, config: BackendConfig, anchor: CGRect? = nil) {
        let session = startSession(source: source, config: config)
        if let anchor { panel.show(near: anchor) } else { panel.show(near: nil) }
        run(session, text: text, config: config)
    }

    /// Looks the same text up again with another Backend, once; settings stay as they are.
    func retry(_ session: LookupSession, with config: BackendConfig) {
        if case .failed = session.status {
            lookup(text: session.sourceText, source: session.source, config: config)
        } else if session.explanationError != nil {
            explain(session, with: config)
        } else {
            lookup(text: session.sourceText, source: session.source, config: config)
        }
    }

    private func run(_ session: LookupSession, text rawText: String, config: BackendConfig) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        session.sourceText = text
        session.direction = Direction.of(text)
        session.status = .translating
        session.historyID = history.record(source: session.source, direction: session.direction, text: text)
        let backend = backend(for: config)

        session.tasks.append(Task {
            guard let engine = await readyEngine() else {
                session.status = .failed(dictionaryError ?? "Dictionary not loaded.")
                return
            }
            if session.direction == .learn {
                let analysis = engine.offline(text)
                session.analysis = analysis
                countEncounters(in: analysis)
                do {
                    let (translation, corrected) = try await engine.learn(analysis, backend: backend) { progress in
                        await MainActor.run { session.progress = progress }
                    }
                    session.progress = nil
                    guard !Task.isCancelled else { return }
                    session.analysis = corrected
                    session.translation = translation
                    session.status = .done
                    if let id = session.historyID { history.setTranslation(id: id, translation: translation, backend: backend.label) }
                    if settings.alwaysExplain { explain(session) }
                } catch {
                    guard !Task.isCancelled else { return }
                    session.progress = nil
                    session.status = .failed(error.localizedDescription)
                    Task { await refreshStatuses(only: config.id) }
                }
            } else {
                do {
                    let (reply, analysis) = try await engine.reverse(text, backend: backend) { progress in
                        await MainActor.run { session.progress = progress }
                    }
                    session.progress = nil
                    guard !Task.isCancelled else { return }
                    session.analysis = analysis
                    session.translation = reply.chinese
                    session.note = reply.note.isEmpty ? nil : reply.note
                    session.status = .done
                    if let id = session.historyID { history.setTranslation(id: id, translation: reply.chinese, backend: backend.label) }
                } catch {
                    guard !Task.isCancelled else { return }
                    session.progress = nil
                    session.status = .failed(error.localizedDescription)
                    Task { await refreshStatuses(only: config.id) }
                }
            }
        })
    }

    /// Explains the text, or for a text too long for the Backend, its next part.
    func explain(_ session: LookupSession, with config: BackendConfig? = nil) {
        guard !session.isExplaining, let engine else { return }
        let backend = backend(for: config ?? settings.backend(id: session.backendID) ?? settings.backend(local: false))
        session.isExplaining = true
        session.explanationError = nil
        let translation = session.direction == .learn ? session.translation : session.sourceText
        session.tasks.append(Task {
            defer { session.isExplaining = false }
            if session.explanationParts == nil {
                session.explanation = ""
                session.explanationParts = await engine.explanationParts(session.chineseText, translation: translation, backend: backend)
            }
            while !Task.isCancelled, var parts = session.explanationParts, let part = parts.current {
                // A failed attempt is rolled back, so retrying never repeats a heading or half an answer.
                let checkpoint = session.explanation
                if parts.count > 1 {
                    session.explanation += (parts.done > 0 ? "\n\n---\n\n" : "") + "**Part \(parts.done + 1) of \(parts.count)**\n\n"
                }
                do {
                    let reference = parts.count == 1 ? translation : nil
                    for try await delta in engine.explain(part, translation: reference, backend: backend) {
                        session.explanation += delta
                    }
                    parts.finishCurrent()
                    session.explanationParts = parts
                    return
                } catch BackendError.contextTooLong {
                    session.explanation = checkpoint
                    // Backends that can't measure only find out by trying; explain a smaller part.
                    guard parts.splitCurrent() else {
                        session.explanationError = BackendError.contextTooLong.localizedDescription
                        return
                    }
                    session.explanationParts = parts
                } catch {
                    session.explanation = checkpoint
                    if !Task.isCancelled { session.explanationError = error.localizedDescription }
                    return
                }
            }
        })
    }

    /// "Highlight Chinese anywhere and tap right ⌘, or press ⌃⌥L.", from the user's own shortcuts.
    var lookupHint: String {
        var ways: [String] = []
        if settings.tapKey != .off { ways.append("tap \(settings.tapKey.displayName.lowercased())") }
        if let combo = settings.hotkeys[.lookupSelection] { ways.append("press \(combo.displayString)") }
        return ways.isEmpty ? "Highlight Chinese anywhere and use the menu bar icon." : "Highlight Chinese anywhere and " + ways.joined(separator: ", or ") + "."
    }

    // MARK: Learning

    private func countEncounters(in analysis: OfflineAnalysis) {
        let saved = Set(workspace.vocabulary().map(\.simplified))
        let seen = Set(analysis.words.map(\.text)).intersection(saved)
        if !seen.isEmpty { history.recordEncounters(seen) }
    }

    func isSaved(_ word: String) -> Bool {
        _ = workspaceRevision
        return workspace.vocabulary().contains { $0.simplified == word }
    }

    func toggleSaved(_ segment: Segment, sentence: String) {
        do {
            if isSaved(segment.text) {
                try workspace.removeFromVocabulary(segment.text)
            } else {
                try workspace.addToVocabulary(VocabularyItem(
                    simplified: segment.text, traditional: segment.isTraditional ? segment.original : "",
                    pinyin: segment.pinyin, gloss: segment.definitions.prefix(4).joined(separator: "; "),
                    sourceSentence: sentence
                ))
            }
        } catch {
            NSSound.beep()
        }
        workspaceRevision += 1
    }

    func addTerm(_ term: Term) {
        try? workspace.upsertTerm(term)
        workspaceRevision += 1
    }

    func term(for word: String) -> Term? {
        _ = workspaceRevision
        return workspace.terms().first { $0.chinese == word }
    }

    func encounterCounts() -> [String: Int] {
        _ = workspaceRevision
        return history.encounterCounts()
    }

    /// Words at or below My level count as known.
    func isKnown(_ segment: Segment) -> Bool {
        guard settings.myLevel > 0, let level = segment.hskLevel else { return false }
        return level <= settings.myLevel
    }
}

/// Resumes a continuation with whichever result arrives first.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<T, Never>, with value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
}
