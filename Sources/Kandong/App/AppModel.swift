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
            // e.g. a Local backend whose URL now points off this Mac stops being the Local one.
            let normalized = settings.normalized()
            if normalized != settings { settings = normalized }
            saveSettings()
            applySettings(previous: oldValue)
            stopStaleDownloads(previous: oldValue)
        }
    }

    private(set) var workspace: Workspace
    /// Bumped whenever Workspace files change, so views re-read them.
    private(set) var workspaceRevision = 0
    private(set) var engine: LookupEngine?
    private(set) var dictionaryError: String?
    /// The Workspace's add-on dictionaries, as last loaded.
    private(set) var addOns: [AddOnDictionary] = []
    /// A technical-terms download under way, or why the last one failed.
    private(set) var addOnStatus: AddOnStatus?
    let history: HistoryStore
    var session: LookupSession?
    /// Last known readiness of each Backend, by id.
    private(set) var statuses: [String: BackendStatus] = [:]
    /// Bumped per Backend on each check, so a slow old check can't overwrite a newer result.
    @ObservationIgnored private var statusChecks: [String: Int] = [:]
    /// The models Kandong recommends for LM Studio; the bundled list until the latest is fetched.
    private(set) var modelCatalog = LocalModelCatalog.bundled
    @ObservationIgnored private var catalogLoaded = false
    /// A recommended model being downloaded into an LM Studio Backend, by Backend id.
    private(set) var modelDownloads: [String: ModelDownload] = [:]
    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]

    @ObservationIgnored private var analyzerTask: Task<(OfflineAnalyzer, [AddOnDictionary])?, Never>?
    /// Bumped on each dictionary load, so an older load finishing late is ignored.
    @ObservationIgnored private var dictionaryGeneration = 0
    /// The add-on files the dictionary was loaded from, to notice changes made outside Kandong.
    @ObservationIgnored private var loadedAddOnSignature = ""
    @ObservationIgnored private var hotkeys: HotkeyCenter?
    @ObservationIgnored private var tapMonitor: ModifierTapMonitor?
    /// A model for rendering previews: no shortcuts, no saved settings, History in memory.
    @ObservationIgnored let isPreview: Bool
    @ObservationIgnored lazy var panel = ResultPanelController(model: self)

    init() {
        isPreview = false
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

    /// A model that touches nothing outside itself, for rendering previews: `settings` as given, an
    /// empty Workspace in `workspacePath`, History in memory, no shortcuts.
    init(previewSettings: AppSettings, workspacePath: String) {
        isPreview = true
        var settings = previewSettings
        settings.workspacePath = workspacePath
        self.settings = settings
        workspace = Workspace(path: workspacePath)
        history = try! HistoryStore.inMemory()
        try? workspace.ensureExists()
        loadDictionary()
    }

    // MARK: Settings

    private func saveSettings() {
        guard !isPreview else { return }
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "settings") }
    }

    private func applySettings(previous: AppSettings?) {
        if previous?.hotkeys != settings.hotkeys || previous == nil { hotkeys?.register(settings.hotkeys) }
        tapMonitor?.key = settings.tapKey
        if previous == nil || previous?.workspacePath != settings.workspacePath { openWorkspace() }
        if previous?.codex.executablePath != settings.codex.executablePath {
            Task { await CodexAppServer.shared.stop() }
        }
    }

    /// Lets the shortcut recorder capture keys that are currently registered.
    func suspendHotkeys(_ suspended: Bool) {
        suspended ? hotkeys?.unregisterAll() : hotkeys?.register(settings.hotkeys)
    }

    private func openWorkspace() {
        workspace.stopWatching()
        workspace = Workspace(path: settings.workspacePath)
        try? workspace.ensureExists()
        if let engine { self.engine = LookupEngine(analyzer: engine.analyzer, workspace: workspace) }
        // Another Workspace may have other add-on dictionaries (not at launch: init loads them next).
        if analyzerTask != nil { loadDictionary() }
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

    /// Loads CC-CEDICT and the Workspace's add-on dictionaries; called again when the add-ons or the
    /// Workspace change. Lookups keep the old dictionary until the new one is ready.
    private func loadDictionary() {
        dictionaryGeneration += 1
        let generation = dictionaryGeneration
        let directory = Self.dataDirectory
        let addOnFolder = workspace.dictionariesURL
        loadedAddOnSignature = AddOnDictionary.signature(of: addOnFolder)
        let task = Task.detached(priority: .userInitiated) { () -> (OfflineAnalyzer, [AddOnDictionary])? in
            let addOns = AddOnDictionary.all(in: addOnFolder)
            guard let dict = try? CEDict(contentsOf: directory.appendingPathComponent("cedict_ts.u8"), addOns: addOns) else { return nil }
            let hsk = (try? HSKTable(contentsOf: directory.appendingPathComponent("hsk.tsv"))) ?? HSKTable()
            // The list in Settings doesn't need each file's text.
            return (OfflineAnalyzer(dictionary: dict, hsk: hsk), addOns.map { var addOn = $0; addOn.text = ""; return addOn })
        }
        analyzerTask = task
        Task {
            let result = await task.value
            guard generation == dictionaryGeneration else { return }
            if let (analyzer, addOns) = result {
                engine = LookupEngine(analyzer: analyzer, workspace: workspace)
                self.addOns = addOns
            } else {
                dictionaryError = "Dictionary data missing in \(directory.path). Run scripts/fetch-data.sh and rebuild."
            }
        }
    }

    /// Reloads the dictionary if add-on files were added, changed or removed outside Kandong.
    func reloadDictionariesIfChanged() {
        guard analyzerTask != nil, AddOnDictionary.signature(of: workspace.dictionariesURL) != loadedAddOnSignature else { return }
        loadDictionary()
    }

    // MARK: Add-on dictionaries

    /// Downloads (or updates) the technical-terms glossary into the Workspace.
    func downloadTechnicalTerms() {
        guard addOnStatus != .working else { return }
        addOnStatus = .working
        let folder = workspace.dictionariesURL
        Task {
            do {
                _ = try await ETOGlossary.download(into: folder)
                // Only if the Workspace is still the one it was downloaded into.
                guard folder == workspace.dictionariesURL else { addOnStatus = nil; return }
                addOnStatus = nil
                loadDictionary()
            } catch {
                addOnStatus = folder == workspace.dictionariesURL ? .failed(error.localizedDescription) : nil
            }
        }
    }

    func removeAddOn(_ addOn: AddOnDictionary) {
        do {
            try FileManager.default.removeItem(at: addOn.url)
            if case .failed? = addOnStatus { addOnStatus = nil }
        } catch {
            addOnStatus = .failed("Couldn't remove \(addOn.name): \(error.localizedDescription)")
        }
        loadDictionary()
    }

    enum AddOnStatus: Equatable { case working, failed(String) }

    func readyEngine() async -> LookupEngine? {
        reloadDictionariesIfChanged()
        if let engine { return engine }
        // The first load; a newer one may start while waiting, so wait for the latest.
        while true {
            let generation = dictionaryGeneration
            guard let (analyzer, _) = await analyzerTask?.value else { return nil }
            guard generation == dictionaryGeneration else { continue }
            if engine == nil { engine = LookupEngine(analyzer: analyzer, workspace: workspace) }
            return engine
        }
    }

    // MARK: Backends

    func backend(for config: BackendConfig) -> AIBackend {
        switch config.type {
        case .appleIntelligence: AppleIntelligenceBackend(readingMode: config.readingMode)
        case .codex: CodexBackend(settings: settings.codex, readingMode: config.readingMode)
        case .openAICompatible: OpenAICompatibleBackend(config: config, apiKey: Keychain.read(config.keychainAccount))
        }
    }

    // MARK: Local models

    /// Fetches the latest recommended models once per launch.
    func loadModelCatalog() async {
        guard !catalogLoaded else { return }
        catalogLoaded = true
        modelCatalog = await LocalModelCatalog.load()
    }

    /// Downloads a recommended model into an LM Studio Backend, loads it, and makes it the Backend's model.
    func download(_ recommended: RecommendedModel, into configID: String) {
        guard modelDownloads[configID]?.isActive != true, let config = settings.backend(id: configID),
              let baseURL = config.openAI?.baseURL else { return }
        let modelBefore = config.openAI?.model ?? ""
        modelDownloads[configID] = .downloading(model: recommended.id, fraction: 0, detail: "Starting…")
        downloadTasks[configID] = Task {
            do {
                let job: String?
                do {
                    job = try await LMStudio.startDownload(recommended.id, baseURL: baseURL)
                } catch BackendError.http(let status, _) where status == 404 {
                    // LM Studio before 0.4 can't download through its API; show the model in LM Studio instead.
                    finishDownload(configID, nil)
                    if let url = LMStudio.deepLink(huggingFaceRepo: recommended.huggingFace) { NSWorkspace.shared.open(url) }
                    return
                }
                if let job {
                    polling: while true {
                        let progress = try await LMStudio.download(job, baseURL: baseURL)
                        switch progress.state {
                        case .completed: break polling
                        case .failed(let message): throw BackendError.failed(message)
                        case .paused:
                            modelDownloads[configID] = .downloading(model: recommended.id, fraction: progress.fraction, detail: "Paused in LM Studio")
                        case .downloading:
                            let detail = "\(Self.gigabytes(progress.downloadedBytes)) of \(Self.gigabytes(progress.totalBytes)) GB"
                            modelDownloads[configID] = .downloading(model: recommended.id, fraction: progress.fraction, detail: detail)
                        }
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                modelDownloads[configID] = .loading(model: recommended.id)
                try await LMStudio.load(recommended.id, baseURL: baseURL)
                try Task.checkCancellation()
                // Only if the Backend still talks to that server and no other model was picked meanwhile.
                if let index = settings.backends.firstIndex(where: { $0.id == configID }),
                   settings.backends[index].openAI?.baseURL == baseURL, (settings.backends[index].openAI?.model ?? "") == modelBefore {
                    settings.backends[index].openAI?.model = recommended.id
                }
                finishDownload(configID, nil)
            } catch {
                // Stopped by `stopWatchingDownload`, which has already cleared it.
                guard !Task.isCancelled else { return }
                let message = LMStudio.isOutOfMemory(error)
                    ? "This Mac doesn't have enough free memory to load \(recommended.name). Quit some apps, or unload other models in LM Studio, then try again."
                    : error.localizedDescription
                finishDownload(configID, .failed(model: recommended.id, message: message))
            }
            await refreshStatuses(only: configID)
        }
    }

    private func finishDownload(_ configID: String, _ state: ModelDownload?) {
        modelDownloads[configID] = state
        downloadTasks[configID] = nil
    }

    /// Stops following a download; LM Studio carries on with it unless it's stopped there.
    func stopWatchingDownload(for configID: String) {
        downloadTasks[configID]?.cancel()
        finishDownload(configID, nil)
    }

    /// A download is for one server: stop following it when its Backend goes or points elsewhere.
    private func stopStaleDownloads(previous: AppSettings) {
        for id in downloadTasks.keys where settings.backend(id: id)?.openAI?.baseURL != previous.backend(id: id)?.openAI?.baseURL {
            stopWatchingDownload(for: id)
        }
    }

    /// Makes an LM Studio Backend use a model it already has.
    func useModel(_ id: String, for configID: String) {
        guard let index = settings.backends.firstIndex(where: { $0.id == configID }) else { return }
        settings.backends[index].openAI?.model = id
        Task { await refreshStatuses(only: configID) }
    }

    private static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1e9)
    }

    /// Checks every Backend (or one) and remembers whether it can answer.
    func refreshStatuses(only id: String? = nil) async {
        let configs = settings.backends.filter { id == nil || $0.id == id }
        await withTaskGroup(of: (String, Int, BackendStatus).self) { group in
            for config in configs {
                let backend = backend(for: config)
                let check = (statusChecks[config.id] ?? 0) + 1
                statusChecks[config.id] = check
                group.addTask { (config.id, check, await backend.status()) }
            }
            for await (id, check, status) in group where statusChecks[id] == check && settings.backend(id: id) != nil {
                statuses[id] = status
            }
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

    /// A fix's button title, e.g. "Get LM Studio" when the app it would open isn't installed.
    func title(for fix: FixAction) -> String {
        if case .openApp(let bundleID, _) = fix, bundleID == LMStudio.bundleID,
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) == nil {
            return "Get LM Studio"
        }
        return fix.label
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
            } else if bundleID == LMStudio.bundleID {
                NSWorkspace.shared.open(LMStudio.website)
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            await refreshStatuses()
        }
    }

    /// Moves keys to their new accounts, deleting an old one only once the new one reads back.
    private static func moveLegacyKeychainAccounts() {
        for (old, new) in legacyKeychainAccounts {
            guard let key = Keychain.read(old) else { continue }
            if Keychain.read(new) == key {
                Keychain.write("", for: old)
                continue
            }
            // Something else is there, or the Keychain can't say: leave both alone.
            guard Keychain.contains(new) == false else { continue }
            guard Keychain.write(key, for: new), Keychain.read(new) == key else { continue }
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
        // Asked again while the panel still has the keyboard: the user hasn't gone back to select
        // something else. Mixed Chinese and English is said the other way; anything else closes.
        if panel.isVisible, panel.isKey, let session {
            session.canFlip ? flip(session) : panel.close()
            return
        }
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
            // The same mixed Chinese and English again (e.g. with the panel pinned) says it the other way.
            if let session, panel.isVisible, session.canFlip,
               session.sourceText == selection.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                flip(session)
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
        session.backend = config
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

    private func lookup(image: Data, source: LookupSource, config: BackendConfig, anchor: CGRect?) {
        let session = startSession(source: source, config: config)
        session.image = image
        session.status = .readingImage
        if let anchor { panel.show(near: anchor) } else { panel.show(near: nil) }
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

    func lookup(text: String, source: LookupSource, config: BackendConfig, anchor: CGRect? = nil, direction: Direction? = nil) {
        let session = startSession(source: source, config: config)
        if let anchor { panel.show(near: anchor) } else { panel.show(near: nil) }
        run(session, text: text, config: config, direction: direction)
    }

    /// Reads mixed Chinese and English the other way: as it is, or said all in Chinese.
    func flip(_ session: LookupSession) {
        guard session.canFlip else { return }
        lookup(text: session.sourceText, source: session.source, config: session.backend, direction: session.direction.flipped)
    }

    /// Shows a History entry's Result again without asking the AI; looks it up again if it has none.
    func reopen(_ entry: HistoryEntry) {
        guard !entry.translation.isEmpty, let engine else {
            lookup(text: entry.text, source: .history, local: false)
            return
        }
        let config = settings.backends.first { backend(for: $0).label == entry.backend } ?? settings.backend(local: false)
        let session = startSession(source: entry.source, config: config)
        session.backendLabel = entry.backend
        session.sourceText = entry.text
        session.direction = entry.direction
        session.historyID = entry.id
        session.isReopened = true
        session.analysis = engine.offline(entry.direction == .learn ? entry.text : entry.translation)
        session.translation = entry.translation
        session.status = .done
        panel.show(near: nil)
    }

    /// Looks the same thing up again with another Backend, once; settings stay as they are.
    func retry(_ session: LookupSession, with config: BackendConfig) {
        if case .failed = session.status {
            lookUpAgain(session, with: config)
        } else if session.explanationError != nil {
            explain(session, with: config)
        } else {
            lookUpAgain(session, with: config)
        }
    }

    private func lookUpAgain(_ session: LookupSession, with config: BackendConfig) {
        // Still reading an image (or it had no text yet): read it again with the new Backend.
        if session.sourceText.isEmpty, let image = session.image {
            lookup(image: image, source: session.source, config: config, anchor: nil)
        } else {
            lookup(text: session.sourceText, source: session.source, config: config)
        }
    }

    private func run(_ session: LookupSession, text rawText: String, config: BackendConfig, direction: Direction? = nil) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        session.sourceText = text
        session.direction = direction ?? Direction.of(text)
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
                    let (translation, corrected) = try await engine.learn(analysis, backend: backend, progress: { progress in
                        await MainActor.run { session.progress = progress; session.isThinking = false }
                    }, thinking: {
                        await MainActor.run { session.isThinking = true }
                    })
                    session.progress = nil
                    session.isThinking = false
                    guard !Task.isCancelled else { return }
                    session.analysis = corrected
                    session.translation = translation
                    session.status = .done
                    Self.announce("Translation ready")
                    if let id = session.historyID { history.setTranslation(id: id, translation: translation, backend: backend.label) }
                    if settings.alwaysExplain { explain(session) }
                } catch {
                    guard !Task.isCancelled else { return }
                    session.progress = nil
                    session.isThinking = false
                    session.status = .failed(error.localizedDescription)
                    Task { await refreshStatuses(only: config.id) }
                }
            } else {
                do {
                    let (reply, analysis) = try await engine.reverse(text, backend: backend, progress: { progress in
                        await MainActor.run { session.progress = progress; session.isThinking = false }
                    }, thinking: {
                        await MainActor.run { session.isThinking = true }
                    })
                    session.progress = nil
                    session.isThinking = false
                    guard !Task.isCancelled else { return }
                    session.analysis = analysis
                    session.translation = reply.chinese
                    session.note = reply.note.isEmpty ? nil : reply.note
                    session.status = .done
                    Self.announce("Chinese ready")
                    if let id = session.historyID { history.setTranslation(id: id, translation: reply.chinese, backend: backend.label) }
                    // The Reading shows the dictionary's pinyin until the same Backend says how its Chinese
                    // reads in context; the Chinese is ready either way, so a failure here only keeps those.
                    do {
                        let corrected = try await engine.contextReadings(analysis, english: text, backend: backend)
                        guard !Task.isCancelled, self.session === session else { return }
                        session.analysis = corrected
                    } catch {
                        guard !Task.isCancelled else { return }
                        lookupLog.error("context readings failed: \(error.localizedDescription, privacy: .public)")
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    session.progress = nil
                    session.isThinking = false
                    session.status = .failed(error.localizedDescription)
                    Task { await refreshStatuses(only: config.id) }
                }
            }
        })
    }

    /// Explains the text, or for a text too long for the Backend, its next part.
    func explain(_ session: LookupSession, with config: BackendConfig? = nil) {
        // Explain uses the Translation as a reference, so it waits for it.
        guard !session.isExplaining, session.status != .translating, session.status != .readingImage, let engine else { return }
        if let config { session.explanationBackend = config }
        // The Backend this Lookup used (its current settings if it still exists), never a silent
        // switch to another one: a Local Lookup's text must stay on this Mac.
        let chosen = session.explanationBackend ?? session.backend
        let backend = backend(for: settings.backend(id: chosen.id) ?? chosen)
        session.isExplaining = true
        session.explanationError = nil
        let translation = session.direction == .learn ? session.translation : session.sourceText
        session.tasks.append(Task {
            defer { session.isExplaining = false; session.isExplanationThinking = false }
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
                    let thinking: ThinkingHandler = { await MainActor.run { session.isExplanationThinking = true } }
                    for try await delta in engine.explain(part, translation: reference, backend: backend, thinking: thinking) {
                        session.isExplanationThinking = false
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

    /// Tells VoiceOver users that something they're waiting for has arrived.
    static func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
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
