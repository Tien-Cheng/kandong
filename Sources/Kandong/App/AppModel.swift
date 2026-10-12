import AppKit
import Observation
import OSLog
import KandongKit

let lookupLog = Logger(subsystem: "com.tiencheng.kandong", category: "lookup")

/// App-wide state and the Lookup flow.
@MainActor
@Observable
final class AppModel {
    static let customKeyAccount = "custom-api-key"

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

    @ObservationIgnored private var analyzerTask: Task<OfflineAnalyzer?, Never>?
    @ObservationIgnored private var hotkeys: HotkeyCenter!
    @ObservationIgnored private var tapMonitor: ModifierTapMonitor!
    @ObservationIgnored lazy var panel = ResultPanelController(model: self)

    init() {
        let stored = UserDefaults.standard.data(forKey: "settings").flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
        settings = stored ?? AppSettings()
        workspace = Workspace(path: (stored ?? AppSettings()).workspacePath)
        history = (try? HistoryStore(url: HistoryStore.defaultURL)) ?? (try! HistoryStore.inMemory())

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

    func backend(local: Bool) -> AIBackend {
        backend(for: local ? settings.localBackend : settings.defaultBackend)
    }

    func backend(for kind: BackendKind) -> AIBackend {
        switch kind {
        case .appleIntelligence: AppleIntelligenceBackend()
        case .codex: CodexBackend(settings: settings.codex)
        case .lmStudio: OpenAICompatibleBackend(kind: .lmStudio, settings: settings.lmStudio)
        case .custom: OpenAICompatibleBackend(kind: .custom, settings: settings.custom, apiKey: Keychain.read(Self.customKeyAccount))
        }
    }

    /// Whether text sent to this Backend stays on this Mac.
    func isOnDevice(_ kind: BackendKind) -> Bool {
        if kind == .appleIntelligence { return true }
        guard let settings = settings.openAISettings(for: kind), let host = URL(string: settings.baseURL)?.host else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    // MARK: Lookups

    func perform(_ action: HotkeyAction, local: Bool) {
        switch action {
        case .lookupSelection: lookupSelection(local: local)
        case .captureScreen: captureScreen(local: local)
        case .lookupClipboard: lookupClipboard(local: local)
        }
    }

    func lookupSelection(local: Bool) {
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
            lookup(text: selection.text, source: .selection, local: local, anchor: selection.bounds ?? CGRect(origin: anchor, size: .zero))
        }
    }

    func captureScreen(local: Bool) {
        Task {
            guard let image = await ScreenCapture.captureRegion() else { return }
            lookup(image: image, source: .screenCapture, local: local, anchor: CGRect(origin: NSEvent.mouseLocation, size: .zero))
        }
    }

    func lookupClipboard(local: Bool) {
        let anchor = CGRect(origin: NSEvent.mouseLocation, size: .zero)
        switch ClipboardReader.read() {
        case .image(let data): lookup(image: data, source: .clipboard, local: local, anchor: anchor)
        case .text(let text): lookup(text: text, source: .clipboard, local: local, anchor: anchor)
        case nil: showMessage("The clipboard has no text or image.", source: .clipboard, anchor: anchor.origin)
        }
    }

    private func startSession(source: LookupSource, local: Bool) -> LookupSession {
        session?.cancel()
        let session = LookupSession(source: source)
        let kind = local ? settings.localBackend : settings.defaultBackend
        if kind == .appleIntelligence { AppleIntelligenceBackend.prewarm() }
        session.backendLabel = backend(for: kind).label
        session.backendIsLocal = isOnDevice(kind)
        session.usesLocalBackend = local
        self.session = session
        return session
    }

    private func showMessage(_ message: String, source: LookupSource, anchor: CGPoint) {
        let session = startSession(source: source, local: false)
        session.message = message
        session.status = .done
        panel.show(near: CGRect(origin: anchor, size: .zero))
    }

    func lookup(image: Data, source: LookupSource, local: Bool, anchor: CGRect) {
        let session = startSession(source: source, local: local)
        session.status = .readingImage
        panel.show(near: anchor)
        let backend = backend(local: local)
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
            run(session, text: text, local: local)
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
        let session = startSession(source: source, local: local)
        if let anchor { panel.show(near: anchor) } else { panel.show(near: nil) }
        run(session, text: text, local: local)
    }

    private func run(_ session: LookupSession, text rawText: String, local: Bool) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        session.sourceText = text
        session.direction = Direction.of(text)
        session.status = .translating
        session.historyID = history.record(source: session.source, direction: session.direction, text: text)
        let backend = backend(local: local)

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
                    if settings.alwaysExplain { explain(session, local: local) }
                } catch {
                    guard !Task.isCancelled else { return }
                    session.status = .failed(error.localizedDescription)
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
                    session.status = .failed(error.localizedDescription)
                }
            }
        })
    }

    /// Explains the text, or for a text too long for the Backend, its next part.
    func explain(_ session: LookupSession, local: Bool? = nil) {
        guard !session.isExplaining, let engine else { return }
        let backend = backend(local: local ?? session.usesLocalBackend)
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
