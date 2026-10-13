import Foundation
import Testing
@testable import KandongKit

@Suite struct CSVTests {
    @Test func roundTripsAwkwardFields() {
        let rows = [["东西", "thing", "dōngxi, \"not\" east and west"], ["多行", "multi\nline", ""]]
        let text = CSV.write(header: ["chinese", "english", "note"], rows: rows)
        #expect(Array(CSV.parse(text).dropFirst()) == rows)
    }

    @Test func readsCRLFAndBOM() {
        let records = CSV.records("\u{FEFF}Chinese,English\r\n微信,WeChat\r\n")
        #expect(records == [["chinese": "微信", "english": "WeChat"]])
    }
}

@Suite struct WorkspaceTests {
    func makeWorkspace() throws -> Workspace {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kandong-test-\(UUID().uuidString)")
        let workspace = Workspace(folder: folder)
        try workspace.ensureExists()
        return workspace
    }

    @Test func seedsStarterFiles() throws {
        let workspace = try makeWorkspace()
        #expect(!workspace.context().isEmpty)
        #expect(workspace.terms().contains { $0.chinese == "加油" })
        #expect(workspace.vocabulary().isEmpty)
    }

    @Test func seesExternalEdits() throws {
        let workspace = try makeWorkspace()
        _ = workspace.terms()
        // An agent appends a row in place.
        let handle = try FileHandle(forWritingTo: workspace.termsURL)
        handle.seekToEndOfFile()
        handle.write(Data("饺子,dumplings,\n".utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: workspace.termsURL.path)
        #expect(workspace.terms().contains { $0.chinese == "饺子" && $0.english == "dumplings" })
    }

    @Test func matchesTermsInText() throws {
        let workspace = try makeWorkspace()
        try workspace.upsertTerm(Term(chinese: "躺平", english: "lie flat"))
        #expect(workspace.matchingTerms(in: "我想躺平").map(\.chinese) == ["躺平"])
        #expect(workspace.matchingTerms(in: "time to lie flat").map(\.chinese) == ["躺平"])
        #expect(workspace.matchingTerms(in: "没有").isEmpty)
    }

    @Test func savesVocabulary() throws {
        let workspace = try makeWorkspace()
        try workspace.addToVocabulary(VocabularyItem(simplified: "沟通", traditional: "溝通", pinyin: "gōu tōng", gloss: "to communicate", sourceSentence: "你跟老师沟通过了吗？"))
        try workspace.addToVocabulary(VocabularyItem(simplified: "沟通", traditional: "溝通", pinyin: "gōu tōng", gloss: "to communicate", sourceSentence: "again"))
        #expect(workspace.vocabulary().count == 1)
        #expect(workspace.vocabulary().first?.sourceSentence == "again")
        try workspace.removeFromVocabulary("沟通")
        #expect(workspace.vocabulary().isEmpty)
    }
}

@Suite struct PromptTests {
    @Test func parsesJSONWrappedInChatter() throws {
        let reply = "<think>hmm</think>Sure! ```json\n{\"translation\": \"Hi\", \"readingCorrections\": [{\"word\": \"了\", \"pinyin\": \"liǎo\"}]}\n```"
        let parsed = try Prompts.parseLearn(reply)
        #expect(parsed.translation == "Hi")
        #expect(parsed.readingCorrections.first?.pinyin == "liǎo")
    }

    @Test func rejectsReplyWithoutJSON() {
        #expect(throws: BackendError.self) { try Prompts.parseLearn("no idea") }
    }

    @Test func includesTermsAndContext() {
        let analysis = OfflineAnalysis(source: "微信", segments: [Segment(id: 0, kind: .word, text: "微信", original: "微信", syllables: [Syllable(text: "wēi", tone: 1), Syllable(text: "xìn", tone: 4)])])
        let request = Prompts.learn(text: "微信", analysis: analysis, context: "I am a beginner", terms: [Term(chinese: "微信", english: "WeChat")])
        #expect(request.user.contains("微信 → WeChat"))
        #expect(request.user.contains("I am a beginner"))
        #expect(request.user.contains("微信 [wēi xìn]"))
        #expect(request.schema != nil)
    }

    @Test func translationOnlyLeavesOutReadings() throws {
        let analysis = OfflineAnalysis(source: "微信", segments: [Segment(id: 0, kind: .word, text: "微信", original: "微信", syllables: [Syllable(text: "wēi", tone: 1), Syllable(text: "xìn", tone: 4)])])
        let request = Prompts.learn(text: "微信", analysis: analysis, context: "", terms: [], askForReadings: false)
        #expect(!request.user.contains("[wēi xìn]"))
        #expect(!request.system.contains("readingCorrections"))
        #expect(request.schema == Prompts.translationSchema)
        #expect(try Prompts.parseLearn(#"{"translation": "WeChat"}"#).readingCorrections.isEmpty)
    }

    @Test func directionFollowsScript() {
        #expect(Direction.of("good morning") == .reverse)
        #expect(Direction.of("OK明白") == .learn)
    }
}

@Suite(.enabled(if: TestData.hasDictionary, "run scripts/fetch-data.sh"))
struct CorrectionTests {
    @Test func appliesContextualCorrection() throws {
        let analyzer = TestData.analyzer!
        let engine = LookupEngine(analyzer: analyzer, workspace: Workspace(path: NSTemporaryDirectory()))
        let analysis = analyzer.analyze("长大")
        let corrected = engine.applyCorrections([.init(word: "长大", pinyin: "zhǎngdà")], to: analysis)
        let word = corrected.words.first { $0.text == "长大" }
        #expect(word?.pinyin == "zhǎng dà")
        // Same as the dictionary already said → not marked as corrected.
        #expect(word?.readingCorrected == false)

        let forced = engine.applyCorrections([.init(word: "长大", pinyin: "cháng dà")], to: analysis)
        let changed = forced.words.first { $0.text == "长大" }
        #expect(changed?.readingCorrected == true)
        #expect(changed?.alternativeReadings.first == "zhǎng dà")
    }
}

@Suite struct HistoryStoreTests {
    @Test func recordsSearchesAndPrunes() throws {
        let store = try HistoryStore.inMemory()
        let old = store.record(source: .selection, direction: .learn, text: "旧的", date: Date().addingTimeInterval(-100 * 86_400))
        let id = store.record(source: .clipboard, direction: .learn, text: "你好")
        store.setTranslation(id: id, translation: "Hello", backend: "Codex")
        #expect(store.recent(matching: "Hello").map(\.id) == [id])
        store.prune(olderThanDays: 90)
        #expect(!store.recent().contains { $0.id == old })
    }

    @Test func countsEncounters() throws {
        let store = try HistoryStore.inMemory()
        store.recordEncounters(["沟通", "发音"])
        store.recordEncounters(["沟通"])
        #expect(store.encounterCounts() == ["沟通": 2, "发音": 1])
    }
}

@Suite struct SettingsTests {
    @Test func toleratesMissingKeys() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"myLevel": 3, "codex": {"model": "x"}}"#.utf8))
        #expect(settings.myLevel == 3)
        #expect(settings.codex.model == "x")
        #expect(settings.codex.effort == "low")
        #expect(settings.hotkeys[.captureScreen] == AppSettings.defaultHotkeys[.captureScreen])
        #expect(settings.tapKey == .rightCommand)
    }

    @Test func freshInstallsUseAppleIntelligence() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(settings.defaultBackendID == "apple-intelligence")
        #expect(settings.localBackendID == "apple-intelligence")
        #expect(settings.backends.map(\.id) == ["apple-intelligence", "codex", "lmstudio"])
    }

    @Test func keepsExistingBackendChoices() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"defaultBackend": "codex", "localBackend": "lmStudio"}"#.utf8))
        #expect(settings.defaultBackendID == "codex")
        #expect(settings.localBackendID == "lmstudio")
    }

    @Test func turnsLegacyEndpointsIntoBackends() throws {
        let legacy = #"{"defaultBackend": "custom", "localBackend": "custom", "lmStudio": {"baseURL": "http://localhost:1234/v1", "model": "qwen3", "vision": "auto"}, "custom": {"baseURL": "http://localhost:11434/v1", "model": "gemma", "vision": "no"}}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        #expect(settings.backends.map(\.id) == ["apple-intelligence", "codex", "lmstudio", "custom"])
        #expect(settings.backend(id: "lmstudio")?.openAI?.model == "qwen3")
        let custom = try #require(settings.backend(id: "custom"))
        #expect(custom.preset == .ollama)
        #expect(custom.name == "Ollama")
        #expect(custom.openAI?.vision == VisionSupport.no)
        #expect(settings.defaultBackendID == "custom")
        #expect(settings.localBackendID == "custom")
        #expect(legacyKeychainAccounts.first?.to == custom.keychainAccount)
        // Once saved in the new shape, it reads back the same.
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func localBackendMustStayOnThisMac() throws {
        let legacy = #"{"localBackend": "custom", "custom": {"baseURL": "https://api.example.com/v1"}}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        #expect(settings.localBackendID == "apple-intelligence")
        #expect(!settings.localCandidates.contains { $0.id == "custom" })
    }

    @Test func removingTheDefaultFallsBackToAppleIntelligence() {
        var settings = AppSettings()
        let added = BackendConfig.openAI(.openRouter)
        settings.backends.append(added)
        settings.defaultBackendID = added.id
        settings.removeBackend(id: added.id)
        settings.removeBackend(id: "codex")
        #expect(settings.defaultBackendID == "apple-intelligence")
        #expect(settings.backends.map(\.id) == ["apple-intelligence", "codex", "lmstudio"], "built-ins can't be removed")
    }

    @Test func localBackendStopsBeingLocalWhenItsURLGoesRemote() {
        var settings = AppSettings()
        settings.localBackendID = "lmstudio"
        #expect(settings.backend(local: true).id == "lmstudio")
        let index = settings.backends.firstIndex { $0.id == "lmstudio" }!
        settings.backends[index].openAI?.baseURL = "https://lmstudio.example.com/v1"
        #expect(settings.backend(local: true).id == "apple-intelligence")
        #expect(settings.normalized().localBackendID == "apple-intelligence")
    }

    @Test func migratesAChosenCustomEndpointEvenWithoutItsSettings() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"defaultBackend": "custom", "localBackend": "custom"}"#.utf8))
        #expect(settings.defaultBackendID == "custom")
        #expect(settings.localBackendID == "custom")
        #expect(settings.backend(id: "custom")?.openAI?.baseURL == "http://localhost:11434/v1")
    }

    @Test func keepsBuiltInsInAnEditedFile() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"backends": [], "defaultBackendID": "gone"}"#.utf8))
        #expect(settings.backends.map(\.id) == ["apple-intelligence", "codex"])
        #expect(settings.defaultBackendID == "apple-intelligence")
    }

    @Test func roundTrips() throws {
        var settings = AppSettings()
        settings.hotkeys[.lookupSelection] = KeyCombo(keyCode: 2, command: true)
        settings.tapKey = .rightControl
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }
}

@Suite struct CodexProtocolTests {
    func server() async throws -> CodexAppServer {
        let script = Bundle.module.url(forResource: "fake_codex", withExtension: "py", subdirectory: "Fixtures")!
        let server = CodexAppServer()
        try await server.launchForTesting(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-I", script.path])
        return server
    }

    @Test func streamsATurn() async throws {
        let backend = CodexBackend(settings: CodexSettings(), server: try await server())
        let reply = try await backend.complete(AIRequest(system: "s", user: "你好", schema: Prompts.learnSchema))
        #expect(try Prompts.parseLearn(reply).translation == "Hello")
    }

    @Test func keepsStreamedDeltasInOrder() async throws {
        let backend = CodexBackend(settings: CodexSettings(), server: try await server())
        let reply = try await backend.complete(AIRequest(system: "s", user: "MANY"))
        #expect(reply == (0..<300).map { "\($0)," }.joined())
    }

    @Test func deliversTheLastReplyBeforeAnExit() async throws {
        for _ in 0..<5 {
            let backend = CodexBackend(settings: CodexSettings(), server: try await server())
            let reply = try await backend.complete(AIRequest(system: "s", user: "EXIT"))
            #expect(reply.count == 200000)
        }
    }

    @Test func surfacesFailedTurns() async throws {
        let backend = CodexBackend(settings: CodexSettings(), server: try await server())
        await #expect(throws: BackendError.failed("boom")) {
            _ = try await backend.complete(AIRequest(system: "s", user: "FAIL"))
        }
    }

    @Test func listsModels() async throws {
        let models = try await server().models(executablePath: "")
        #expect(models.map(\.id) == ["fast"])
        #expect(models.first?.canReadImages == true)
    }
}

/// Real Codex round trips. Opt in: `KANDONG_LIVE=1 swift test --filter LiveCodexTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KANDONG_LIVE"] == "1" && TestData.hasDictionary))
struct LiveCodexTests {
    let engine = LookupEngine(analyzer: TestData.analyzer!, workspace: {
        let workspace = Workspace(folder: FileManager.default.temporaryDirectory.appendingPathComponent("kandong-live-\(UUID().uuidString)"))
        try? workspace.ensureExists()
        try? workspace.upsertTerm(Term(chinese: "加油", english: "you've got this"))
        return workspace
    }())
    let backend = CodexBackend(settings: CodexSettings())

    @Test func learnHonoursTerms() async throws {
        let (translation, analysis) = try await engine.learn(engine.offline("明天考试，@Xiao Ming 加油！今晚再看一遍Quizlet"), backend: backend)
        #expect(translation.localizedCaseInsensitiveContains("got this"))
        #expect(translation.contains("@Xiao Ming"))
        #expect(translation.contains("Quizlet"))
        #expect(analysis.hasChinese)
    }

    @Test func reverseProducesChinese() async throws {
        let (reply, analysis) = try await engine.reverse("Shall we practise speaking together this weekend?", backend: backend)
        #expect(reply.chinese.containsHan)
        #expect(analysis.hasChinese)
    }

    @Test func explainStreamsMarkdown() async throws {
        var text = ""
        for try await delta in engine.explain("你跟老师沟通过了吗？", translation: nil, backend: backend) { text += delta }
        #expect(text.contains("过"))
    }
}

@Suite struct PartialJSONTests {
    @Test func readsAStringStillBeingWritten() {
        #expect(PartialJSON.stringValue(of: "translation", in: #"{"translation": "Chinese class at"#) == "Chinese class at")
        #expect(PartialJSON.stringValue(of: "translation", in: #"{"readingCorrections": [], "translation" : "Done"}"#) == "Done")
        #expect(PartialJSON.stringValue(of: "translation", in: #"{"transl"#) == nil)
        #expect(PartialJSON.stringValue(of: "translation", in: #"{"translation": "#) == nil)
    }

    @Test func decodesEscapesAndStopsBeforeAHalfWrittenOne() {
        #expect(PartialJSON.stringValue(of: "t", in: #"{"t": "a\"b\nc\\d"#) == "a\"b\nc\\d")
        #expect(PartialJSON.stringValue(of: "t", in: #"{"t": "caf\u00e9 \ud83d\ude00!"}"#) == "café 😀!")
        #expect(PartialJSON.stringValue(of: "t", in: #"{"t": "ok\u00"#) == "ok")
        #expect(PartialJSON.stringValue(of: "t", in: #"{"t": "ok\ud83d"#) == "ok")
        #expect(PartialJSON.stringValue(of: "t", in: #"{"t": "ok\"#) == "ok")
    }

    @Test func survivesMalformedSurrogates() {
        #expect(PartialJSON.stringValue(of: "t", in: #"{"t": "a\ud800\u0000b"}"#) == "a")
        #expect(PartialJSON.stringValue(of: "t", in: #"{"t": "a\ud800\ue000b"}"#) == "a")
        #expect(PartialJSON.stringValue(of: "t", in: #"{"t": "a\udc00b"}"#) == "a")
    }

    @Test func onlyMatchesKeys() {
        #expect(PartialJSON.stringValue(of: "chinese", in: #"{"note": "chinese", "chinese": "你好"}"#) == "你好")
        #expect(PartialJSON.stringValue(of: "translation", in: #"{"translation": "the word \"translation\": means"}"#) == #"the word "translation": means"#)
        #expect(PartialJSON.stringValue(of: "chinese", in: #"{"note": "chinese"#) == nil)
    }
}

@Suite struct ContextOverflowTests {
    @Test func recognisesServersOverflowMessages() {
        let overflows = [
            "This model's maximum context length is 8192 tokens. However, your messages resulted in 9000 tokens.",
            #"{"error":{"code":"context_length_exceeded"}}"#,
            "the request exceeds the available context size, try increasing it",
            "Trying to keep the first 9000 tokens when context the overflows. However, the model is loaded with context length of only 4096 tokens",
        ]
        for message in overflows { #expect(OpenAICompatibleBackend.isContextOverflow(status: 400, body: message), "\(message)") }
        #expect(!OpenAICompatibleBackend.isContextOverflow(status: 400, body: "Invalid value for n_ctx: must be positive"))
        #expect(!OpenAICompatibleBackend.isContextOverflow(status: 400, body: "response_format json_schema is not supported"))
        #expect(!OpenAICompatibleBackend.isContextOverflow(status: 401, body: "maximum context length"))
    }
}

@Suite(.serialized) struct OpenAICompatibleTests {
    /// Starts the fake LM Studio server on a free port; the caller terminates it.
    func startServer(rejectSchema: Bool = false) async throws -> (Process, String) {
        try await FakeLMStudio.start(rejectSchema ? ["--reject-schema"] : [])
    }
}

enum FakeLMStudio {
    /// Starts the fake LM Studio server with `flags` on a free port; the caller terminates it.
    static func start(_ flags: [String] = []) async throws -> (Process, String) {
        let script = Bundle.module.url(forResource: "fake_lmstudio", withExtension: "py", subdirectory: "Fixtures")!
        let port = Int.random(in: 20_000...40_000)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", script.path, "\(port)"] + flags
        try process.run()
        let base = "http://127.0.0.1:\(port)/v1"
        for _ in 0..<50 {
            if (try? await LMStudio.models(baseURL: base)) != nil { return (process, base) }
            try await Task.sleep(for: .milliseconds(100))
        }
        process.terminate()
        throw BackendError.failed("fake server did not start")
    }

    /// What the server was sent, one entry per chat request.
    static func log(_ base: String) async throws -> [JSONValue] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: base.replacingOccurrences(of: "/v1", with: "/log"))!)
        return try JSONValue.decode(data).array ?? []
    }
}

extension OpenAICompatibleTests {

    @Test func listsModelsAndDetectsVision() async throws {
        let (server, base) = try await startServer()
        defer { server.terminate() }
        let models = try await LMStudio.models(baseURL: base)
        #expect(models.map(\.id) == ["fake-vlm", "fake-plain"], "embedding models are hidden, loaded ones come first")
        #expect(models[0].reasoningOptions == ["off", "on"] && models[0].canReadImages)
        #expect(!models[1].canThink && !models[1].canReadImages)
        let backend = OpenAICompatibleBackend(config: Self.config(.lmStudio, base))
        #expect(await backend.supportsImages())
        #expect(await !OpenAICompatibleBackend(config: Self.config(.lmStudio, base, vision: .no)).supportsImages())
    }

    @Test func streamsLearnReplyStrippingThinking() async throws {
        let (server, base) = try await startServer()
        defer { server.terminate() }
        let backend = OpenAICompatibleBackend(config: Self.config(.lmStudio, base))
        let reply = try await backend.complete(AIRequest(system: "readingCorrections", user: "今天", schema: Prompts.learnSchema))
        #expect(try Prompts.parseLearn(reply).translation == "[local] Chinese class at three this afternoon")
    }

    @Test func retriesWithoutSchemaWhenRejected() async throws {
        let (server, base) = try await startServer(rejectSchema: true)
        defer { server.terminate() }
        let backend = OpenAICompatibleBackend(config: Self.config(.other, base))
        let reply = try await backend.complete(AIRequest(system: "readingCorrections", user: "今天", schema: Prompts.learnSchema))
        #expect(try Prompts.parseLearn(reply).translation.hasPrefix("[local]"))
    }

    @Test func sendsImagesAsDataURLs() async throws {
        let (server, base) = try await startServer()
        defer { server.terminate() }
        let backend = OpenAICompatibleBackend(config: Self.config(.lmStudio, base))
        let text = try await backend.complete(Prompts.transcribe(image: Data([0x89, 0x50, 0x4E, 0x47])))
        #expect(text == "今天下午三点上中文课")
        let (data, _) = try await URLSession.shared.data(from: URL(string: base.replacingOccurrences(of: "/v1", with: "/log"))!)
        #expect(try JSONValue.decode(data).array?.last?["image"]?.bool == true)
    }

    @Test func reportsUnreachableServer() async {
        let backend = OpenAICompatibleBackend(config: Self.config(.lmStudio, "http://127.0.0.1:9/v1"))
        await #expect(throws: BackendError.self) { _ = try await backend.complete(AIRequest(system: "", user: "x")) }
    }

    static func config(_ preset: OpenAIPreset, _ base: String, vision: VisionSupport = .auto) -> BackendConfig {
        var config = BackendConfig.openAI(preset)
        config.openAI = OpenAISettings(baseURL: base)
        config.openAI?.vision = vision
        return config
    }

    @Test func reportsWhatEachBackendNeeds() async throws {
        let down = OpenAICompatibleBackend(config: Self.config(.lmStudio, "http://127.0.0.1:9/v1"))
        #expect(await down.status() == .needsSetup("LM Studio's server isn't running.", fix: .openApp(bundleID: LMStudio.bundleID, label: "Open LM Studio")))
        var configured = Self.config(.lmStudio, "http://127.0.0.1:9/v1")
        configured.openAI?.model = "qwen3"
        #expect(await OpenAICompatibleBackend(config: configured).status().isReady == false, "a chosen model doesn't make a stopped server ready")
        let noKey = OpenAICompatibleBackend(config: Self.config(.openRouter, "http://127.0.0.1:9/v1"))
        #expect(await noKey.status() == .needsSetup("Add your OpenRouter API key."))

        let (server, base) = try await startServer()
        defer { server.terminate() }
        let status = await OpenAICompatibleBackend(config: Self.config(.lmStudio, base)).status()
        #expect(status == .ready("On this Mac · fake-vlm"))
    }
}

/// Event sequences as macOS reports them for a real keyboard (flags include device bits).
@Suite struct ModifierTapDetectorTests {
    // Right ⌘ down: command (0x100000) + right-cmd device bit (0x10) + non-coalesced bit (0x100).
    let rightCommandDown: UInt64 = 0x100110
    // Right ⌥ down: option (0x80000) + right-alt device bit (0x40) + 0x100.
    let rightOptionDown: UInt64 = 0x80140
    let up: UInt64 = 0x100

    func run(_ key: TapKey, _ inputs: [ModifierTapDetector.Input]) -> [ModifierTapDetector.Tap] {
        var detector = ModifierTapDetector(key: key)
        return inputs.compactMap { detector.handle($0) }
    }

    func run(_ inputs: [ModifierTapDetector.Input]) -> [ModifierTapDetector.Tap] {
        run(.rightCommand, inputs)
    }

    @Test func quickTapFires() {
        #expect(run([.modifiers(keyCode: 54, flags: rightCommandDown, time: 0), .modifiers(keyCode: 54, flags: up, time: 0.12)])
                == [.init(local: false)])
        #expect(run(.rightOption, [.modifiers(keyCode: 61, flags: rightOptionDown, time: 0), .modifiers(keyCode: 61, flags: up, time: 0.1)])
                == [.init(local: false)])
    }

    @Test func otherRightModifiersDoNotFire() {
        // Right ⌥ is the user's dictation key: it must never trigger the right-⌘ detector.
        #expect(run([.modifiers(keyCode: 61, flags: rightOptionDown, time: 0), .modifiers(keyCode: 61, flags: up, time: 0.1)]).isEmpty)
        // Left ⌘ (key 55, device bit 0x08).
        #expect(run([.modifiers(keyCode: 55, flags: 0x100108, time: 0), .modifiers(keyCode: 55, flags: up, time: 0.1)]).isEmpty)
        #expect(run(.off, [.modifiers(keyCode: 54, flags: rightCommandDown, time: 0), .modifiers(keyCode: 54, flags: up, time: 0.1)]).isEmpty)
    }

    @Test func syntheticEventsWithoutKeyCodeFire() {
        // System Events reports key code 0 with the right device bit.
        #expect(run([.modifiers(keyCode: 0, flags: 0x100010, time: 0), .modifiers(keyCode: 0, flags: 0, time: 0.1)]) == [.init(local: false)])
    }

    @Test func holdingDoesNot() {
        #expect(run([.modifiers(keyCode: 54, flags: rightCommandDown, time: 0), .modifiers(keyCode: 54, flags: up, time: 0.8)]).isEmpty)
    }

    @Test func shortcutsWithTheKeyDoNot() {
        // ⌘C typed with right ⌘.
        #expect(run([.modifiers(keyCode: 54, flags: rightCommandDown, time: 0), .other, .modifiers(keyCode: 54, flags: up, time: 0.1)]).isEmpty)
        // ⌃ already held (a chord), or ⌥ pressed during the tap.
        #expect(run([.modifiers(keyCode: 54, flags: rightCommandDown | 0x40001, time: 0), .modifiers(keyCode: 54, flags: 0x40101, time: 0.1)]).isEmpty)
        #expect(run([.modifiers(keyCode: 54, flags: rightCommandDown, time: 0), .modifiers(keyCode: 58, flags: rightCommandDown | 0x80020, time: 0.05),
                     .modifiers(keyCode: 54, flags: up, time: 0.1)]).isEmpty)
    }

    @Test func shiftMeansLocal() {
        #expect(run([
            .modifiers(keyCode: 56, flags: 0x20102, time: 0),
            .modifiers(keyCode: 54, flags: rightCommandDown | 0x20102, time: 0.05),
            .modifiers(keyCode: 54, flags: 0x20102, time: 0.15),
        ]) == [.init(local: true)])
    }
}

@Suite struct MarkdownLinesTests {
    @Test func parsesBlocks() {
        #expect(MarkdownLines.parse("## Grammar\n- **了**: change of state\n  - nested\n\nPlain") == [
            .heading("Grammar"), .bullet(level: 0, text: "**了**: change of state"), .bullet(level: 1, text: "nested"),
            .blank, .paragraph("Plain"),
        ])
    }

    @Test func forgivesSloppyModelOutput() {
        #expect(MarkdownLines.parse("-**你好** (*nǐ hǎo*): hello") == [.bullet(level: 0, text: "**你好** (*nǐ hǎo*): hello")])
        #expect(MarkdownLines.parse("third tone **.") == [.paragraph("third tone .")])
        #expect(MarkdownLines.parse("-5 degrees") == [.paragraph("-5 degrees")])
        #expect(MarkdownLines.parse("• item") == [.bullet(level: 0, text: "item")])
    }
}
