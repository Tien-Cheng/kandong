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

    @Test func dropsTheFormatAppleEchoes() {
        let english = "Build local multimodal agents"
        #expect(Prompts.withoutFormatEcho("构建本地多模态代理\n响应使用以下JSON格式：{\"type\": \"object\"}", source: english) == "构建本地多模态代理")
        #expect(Prompts.withoutFormatEcho("构建本地多模态代理\n{\"type\": \"object\"}", source: english) == "构建本地多模态代理")
        let steps = "第一步：保存文件。\n第二步：使用JSON格式。\n第三步：发送文件。"
        #expect(Prompts.withoutFormatEcho(steps, source: "Step one: save the file.\nStep two: use JSON format.\nStep three: send it.") == steps)
        let config = "请使用此配置：\n{\"type\":\"object\"}\n然后重启。"
        #expect(Prompts.withoutFormatEcho(config, source: "Use this config:\n{\"type\":\"object\"}\nthen restart.") == config)
        #expect(Prompts.withoutFormatEcho("第一行\n第二行用JSON格式", source: "First line\nsecond line") == "第一行\n第二行用JSON格式",
                "only the framework's own wording counts as an echo")
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
        let request = Prompts.learn(text: "微信", analysis: analysis, context: "", terms: [], readings: .off)
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

@Suite(.enabled(if: TestData.hasDictionary, "run scripts/fetch-data.sh"), .timeLimit(.minutes(1)))
struct CorrectionTests {
    @Test func offersEachAmbiguousWordItsDictionaryReadings() throws {
        let analysis = TestData.analyzer!.analyze("我还没吃饭，请把书还给我。")
        let request = Prompts.learn(text: analysis.source, analysis: analysis, context: "", terms: [], readings: .choose)
        let choices = ReadingChoice.all(in: analysis)
        #expect(choices.filter { $0.word == "还" }.count == 2, "each 还 gets its own choice: \(choices)")
        #expect(choices.allSatisfy { $0.options.count > 1 })
        #expect(request.user.contains("\(choices[0].key) \(choices[0].word): \(choices[0].options.joined(separator: " | "))"))
        let schema = try #require(request.schema)
        #expect(schema["properties"]?["readings"]?["properties"]?[choices[0].key]?["enum"] == .array(choices[0].options.map { .string($0) }))
        #expect(!request.user.contains("Dictionary pinyin"), "only the ambiguous words are sent")

        let plain = TestData.analyzer!.analyze("微信")
        #expect(Prompts.learn(text: "微信", analysis: plain, context: "", terms: [], readings: .choose).schema == Prompts.translationSchema,
                "nothing to choose: just translate")
    }

    @Test func asksOnlyWithTheWholeTextAndOffersEveryOccurrence() throws {
        let analysis = TestData.analyzer!.analyze("请把书还给我。我还没吃饭。")
        let part = Prompts.learn(text: "请把书还给我。", analysis: analysis, context: "", terms: [], readings: .choose)
        #expect(part.schema == Prompts.translationSchema, "a part isn't asked about the whole text's words")
        let long = TestData.analyzer!.analyze(String(repeating: "我还没吃饭。", count: 40))
        let choices = ReadingChoice.all(in: long)
        #expect(choices.filter { $0.word == "还" }.count == 40, "every occurrence is offered")
    }

    @Test func appliesOnlyTheAnswerTheModeAsksFor() async throws {
        let analyzer = TestData.analyzer!
        let engine = LookupEngine(analyzer: analyzer, workspace: Workspace(path: NSTemporaryDirectory()))
        let analysis = analyzer.analyze("我还没吃饭。")
        let key = try #require(ReadingChoice.all(in: analysis).first { $0.word == "还" }).key
        // A server ignoring the schema answers both ways, one of them made up.
        let reply = #"{"translation": "I haven't eaten yet.", "readings": {"\#(key)": "hái"}, "readingCorrections": [{"word": "还", "pinyin": "hài"}]}"#
        func reading(_ mode: ReadingMode) async throws -> String? {
            try await engine.learn(analysis, backend: CannedBackend(reply: reply, readingMode: mode)).analysis.words.first { $0.text == "还" }?.pinyin
        }
        #expect(try await reading(.choose) == "hái")
        #expect(try await reading(.off) == analysis.words.first { $0.text == "还" }?.pinyin)
        #expect(try await reading(.free) == "hài", "free mode takes the model's word, as it always did")
    }

    @Test func appliesChosenReadingsPerOccurrence() throws {
        let analyzer = TestData.analyzer!
        let engine = LookupEngine(analyzer: analyzer, workspace: Workspace(path: NSTemporaryDirectory()))
        let analysis = analyzer.analyze("我还没吃饭，请把书还给我。")
        let both = ReadingChoice.all(in: analysis).filter { $0.word == "还" }
        let first = try #require(both.first), second = try #require(both.last)
        let chosen = engine.applyReadings([first.key: "hái", second.key: "huán", "w999": "x"], to: analysis)
        let readings = chosen.words.filter { $0.text == "还" }.map(\.pinyin)
        #expect(readings == ["hái", "huán"])
        let changed = chosen.words.filter { $0.text == "还" && $0.readingCorrected }
        #expect(changed.count == 1, "only the one that differs from the dictionary is marked")

        let invented = engine.applyReadings([first.key: "hài"], to: analysis)
        #expect(invented.words.first { $0.text == "还" }?.pinyin == analysis.words.first { $0.text == "还" }?.pinyin,
                "a reading the dictionary doesn't have is ignored")
    }

    @Test func correctedReadingTakesThatReadingsMeaning() throws {
        let analyzer = TestData.analyzer!
        let engine = LookupEngine(analyzer: analyzer, workspace: Workspace(path: NSTemporaryDirectory()))
        let analysis = analyzer.analyze("他还没还我钱。")
        let both = ReadingChoice.all(in: analysis).filter { $0.word == "还" }
        let first = try #require(both.first), second = try #require(both.last)
        let chosen = engine.applyReadings([first.key: "hái", second.key: "huán"], to: analysis)
        let words = chosen.words.filter { $0.text == "还" }
        #expect(words.first?.definitions.first == "still", "hái means still, not huán's to pay back")
        #expect(words.last?.definitions.first == "to pay back")
        #expect(chosen.uniqueWords.filter { $0.text == "还" }.map(\.pinyin) == ["hái", "huán"],
                "each reading gets its own row in the Word breakdown")

        let corrected = engine.applyCorrections([.init(word: "还", pinyin: "hái")], to: analyzer.analyze("还"))
        #expect(corrected.words.first?.definitions.first == "still")
    }

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

    // MARK: Reverse

    static let reverseEnglish = "We haven't tested it yet."

    @Test func reverseAsksForReadingsOfItsOwnChinese() throws {
        let analysis = TestData.analyzer!.analyze("我们还没测过。")
        let choices = ReadingChoice.all(in: analysis)
        #expect(choices.contains { $0.word == "还" })
        let choose = try #require(Prompts.readings(of: analysis, english: Self.reverseEnglish, mode: .choose))
        #expect(choose.user.contains(Self.reverseEnglish) && choose.user.contains(analysis.source))
        #expect(choose.user.contains("\(choices[0].key) \(choices[0].word): \(choices[0].options.joined(separator: " | "))"))
        let schema = try #require(choose.schema)
        #expect(schema["required"] == ["readings"], "readings only: the Chinese is already written")
        #expect(schema["properties"]?["readings"]?["properties"]?[choices[0].key]?["enum"] == .array(choices[0].options.map { .string($0) }))

        let free = try #require(Prompts.readings(of: analysis, english: Self.reverseEnglish, mode: .free))
        #expect(free.schema == Prompts.readingCorrectionsSchema)
        #expect(free.user.contains("Dictionary pinyin"))

        #expect(Prompts.readings(of: analysis, english: Self.reverseEnglish, mode: .off) == nil)
        let plain = TestData.analyzer!.analyze("微信")
        #expect(Prompts.readings(of: plain, english: "WeChat", mode: .choose) == nil, "nothing to choose: nothing to ask")
        #expect(Prompts.readings(of: plain, english: "WeChat", mode: .free) == nil)
    }

    @Test func reverseTakesOnlyTheReadingsTheModeAsksFor() async throws {
        let analyzer = TestData.analyzer!
        let engine = LookupEngine(analyzer: analyzer, workspace: Workspace(path: NSTemporaryDirectory()))
        let analysis = analyzer.analyze("我们还没测过。")
        let dictionary = try #require(analysis.words.first { $0.text == "还" })
        #expect(dictionary.pinyin != "hái", "the dictionary's guess is the one to correct")
        let key = try #require(ReadingChoice.all(in: analysis).first { $0.word == "还" }).key
        // A server ignoring the schema answers both ways, one of them made up.
        let both = #"{"readings": {"\#(key)": "hái"}, "readingCorrections": [{"word": "还", "pinyin": "hài"}]}"#
        func word(_ mode: ReadingMode, reply: String = both) async throws -> Segment? {
            let backend = CannedBackend(reply: reply, readingMode: mode)
            return try await engine.contextReadings(analysis, english: Self.reverseEnglish, backend: backend).words.first { $0.text == "还" }
        }
        let chosen = try #require(try await word(.choose))
        #expect(chosen.pinyin == "hái")
        #expect(chosen.readingCorrected)
        #expect(chosen.definitions.first == "still")
        #expect(try await word(.free)?.pinyin == "hài")
        let corrected = try #require(try await word(.free, reply: #"{"readingCorrections": [{"word": "还", "pinyin": "hái"}]}"#))
        #expect(corrected.pinyin == "hái" && corrected.readingCorrected)
        #expect(corrected.definitions.first == "still")
        #expect(try await word(.off)?.pinyin == dictionary.pinyin)
    }

    @Test func reverseKeepsDictionaryReadingsWhenThereIsNothingToAskOrNoRoom() async throws {
        let analyzer = TestData.analyzer!
        let engine = LookupEngine(analyzer: analyzer, workspace: Workspace(path: NSTemporaryDirectory()))
        let analysis = analyzer.analyze("我们还没测过。")
        #expect(try await engine.contextReadings(analysis, english: Self.reverseEnglish, backend: UnaskedBackend(readingMode: .off)) == analysis)
        let plain = analyzer.analyze("微信")
        #expect(try await engine.contextReadings(plain, english: "WeChat", backend: UnaskedBackend(readingMode: .choose)) == plain)
        let full = UnaskedBackend(readingMode: .choose, fitsRequest: false)
        #expect(try await engine.contextReadings(analysis, english: Self.reverseEnglish, backend: full) == analysis)

        struct TooLong: AIBackend {
            var label: String { "Too long" }
            var readingMode: ReadingMode { .choose }
            func supportsImages() async -> Bool { false }
            func respond(to request: AIRequest) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { $0.finish(throwing: BackendError.contextTooLong) }
            }
        }
        #expect(try await engine.contextReadings(analysis, english: Self.reverseEnglish, backend: TooLong()) == analysis)
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
        #expect(settings.hotkeys[.captureScreen] == AppSettings.defaultHotkeys[.captureScreen])
        #expect(settings.tapKey == .rightCommand)
    }

    @Test func freshInstallsUseAppleIntelligence() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(settings.defaultBackendID == "apple-intelligence")
        #expect(settings.localBackendID == "apple-intelligence")
        #expect(settings.backends.map(\.id) == ["apple-intelligence", "chatgpt", "lmstudio"])
    }

    @Test func keepsExistingBackendChoices() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"defaultBackend": "codex", "localBackend": "lmStudio"}"#.utf8))
        #expect(settings.defaultBackendID == "chatgpt")
        #expect(settings.localBackendID == "lmstudio")
    }

    @Test func turnsLegacyEndpointsIntoBackends() throws {
        let legacy = #"{"defaultBackend": "custom", "localBackend": "custom", "lmStudio": {"baseURL": "http://localhost:1234/v1", "model": "qwen3", "vision": "auto"}, "custom": {"baseURL": "http://localhost:11434/v1", "model": "gemma", "vision": "no"}}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        #expect(settings.backends.map(\.id) == ["apple-intelligence", "chatgpt", "lmstudio", "custom"])
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
        settings.removeBackend(id: "chatgpt")
        #expect(settings.defaultBackendID == "apple-intelligence")
        #expect(settings.backends.map(\.id) == ["apple-intelligence", "chatgpt", "lmstudio"], "built-ins can't be removed")
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
        #expect(settings.backends.map(\.id) == ["apple-intelligence", "chatgpt"])
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

@Suite(.serialized, .timeLimit(.minutes(1))) struct OpenAICompatibleTests {
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
        #expect(models[1].canThink == false && !models[1].canReadImages)
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

/// Answers every request with the same reply.
struct CannedBackend: AIBackend {
    let reply: String
    var readingMode: ReadingMode = .free
    var label: String { "Canned" }
    func supportsImages() async -> Bool { false }
    func respond(to request: AIRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.yield(reply); $0.finish() }
    }
}

/// Fails the test if it is asked anything.
struct UnaskedBackend: AIBackend {
    var readingMode: ReadingMode
    var fitsRequest: Bool?
    var label: String { "Unasked" }
    func supportsImages() async -> Bool { false }
    func fits(_ request: AIRequest) async -> Bool? { fitsRequest }
    func respond(to request: AIRequest) -> AsyncThrowingStream<String, Error> {
        Issue.record("asked: \(request.user.prefix(80))")
        return AsyncThrowingStream { $0.finish() }
    }
}

@Suite struct ReadingModeSettingTests {
    @Test func keepsAnExplicitChoiceAndFollowsTheDefaultOtherwise() throws {
        var config = BackendConfig.openAI(.other)
        config.openAI?.baseURL = "http://localhost:8080/v1"
        #expect(config.readingMode == .choose)
        config.readingMode = .choose
        let saved = try JSONDecoder().decode(BackendConfig.self, from: JSONEncoder().encode(config))
        var moved = saved
        moved.openAI?.baseURL = "https://example.org/v1"
        #expect(moved.readingMode == .choose, "an explicit choice survives the default changing")
        var following = BackendConfig.openAI(.other)
        following.openAI?.baseURL = "https://example.org/v1"
        #expect(following.readingMode == .free)
    }

    @Test func toleratesAModeFromANewerVersion() throws {
        let json = #"{"id":"x","name":"X","type":"openAICompatible","preset":"other","openAI":{"baseURL":"https://example.org/v1"},"readingModeSetting":"telepathy"}"#
        let config = try JSONDecoder().decode(BackendConfig.self, from: Data(json.utf8))
        #expect(config.readingModeSetting == nil && config.readingMode == .free)
    }
}

@Suite struct DirectionTests {
    @Test func mixedTextCanGoEitherWay() {
        #expect(Direction.isMixed("这个 feature 明天 ship 吗？"))
        #expect(!Direction.isMixed("你好"), "all Chinese")
        #expect(!Direction.isMixed("Hello there"), "all English")
        #expect(!Direction.isMixed("@张三 看 https://example.com #AI 2026"), "mentions, links, tags and numbers aren't English to translate")
        #expect(Direction.learn.flipped == .reverse)
    }

    @Test func settingsFromBeforeTheLevelQuestion() throws {
        let decode = { (json: String) in try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)) }
        #expect(try decode(#"{"myLevel": 3}"#).hasChosenLevel, "a level already set counts as answered")
        #expect(try !decode(#"{"myLevel": 0}"#).hasChosenLevel)
        #expect(try decode("{}").readingTypeface == .kai)
    }
}
