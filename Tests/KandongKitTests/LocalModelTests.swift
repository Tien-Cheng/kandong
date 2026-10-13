import Foundation
import Testing
@testable import KandongKit

@Suite struct ReasoningTests {
    @Test func fitsLevelsToWhatTheModelOffers() {
        #expect(Reasoning.resolve("low", allowed: ["off", "on"]) == "off", "on/off models translate without thinking")
        #expect(Reasoning.resolve("off", allowed: ["off", "on"]) == "off")
        #expect(Reasoning.resolve("high", allowed: ["off", "low", "medium", "xhigh", "on"]) == "medium")
        #expect(Reasoning.resolve("low", allowed: ["low", "high"]) == "low")
        #expect(Reasoning.resolve("off", allowed: ["low", "high"]) == "low", "a model that always thinks gets its least")
        #expect(Reasoning.resolve("", allowed: ["off", "on"]) == "", "model default stays")
        #expect(Reasoning.resolve("medium", allowed: []) == "medium")
    }

    @Test func sendsReasoningEffort() {
        #expect(Reasoning.effort("off") == "none")
        #expect(Reasoning.effort("low") == "low")
        #expect(Reasoning.effort("") == nil)
        #expect(Reasoning.effort("on") == nil)
    }

    @Test func spotsRepetition() {
        let detector = RepetitionDetector()
        #expect(detector.isRepeating(String(repeating: "我们一起去吧，", count: 60)))
        #expect(detector.isRepeating("Sure. " + String(repeating: "Wait, let me check the reading again. ", count: 10)))
        #expect(detector.isRepeating(String(repeating: "哈", count: 300)))
        #expect(!detector.isRepeating(String(repeating: "哈", count: 30)), "a short burst of laughter is fine")
        let explanation = """
        **Structure**: 你 + 跟 + 老师 + 沟通 + 过 + 了 + 吗？
        - **跟** marks who you do something with: 跟老师 "with the teacher".
        - **沟通** means to communicate, often to sort something out.
        - **过** after a verb says it has happened before: 沟通过 "have talked it over".
        - **了吗** asks whether it has happened yet.
        | Word | Pinyin | Meaning |
        | --- | --- | --- |
        | 跟 | gēn | with |
        | 老师 | lǎoshī | teacher |
        """
        #expect(!detector.isRepeating(explanation))
        let table = "| " + (1...64).map { "Column \($0)" }.joined(separator: " | ") + " |\n|" + String(repeating: " --- |", count: 64)
        #expect(!detector.isRepeating(table), "a table's separator row isn't a loop")
        let laughter = String(repeating: "哈", count: 260)
        #expect(!detector.isRepeating(laughter, source: "他笑了：" + laughter), "copying the source's own repeats isn't a loop")
    }

    @Test func dropsOnlyTheParameterTheServerNamed() {
        #expect(OpenAICompatibleBackend.namesParameter(#"{"error":{"message":"Unrecognized request argument supplied: reasoning_effort"}}"#, "reasoning_effort"))
        #expect(!OpenAICompatibleBackend.namesParameter(
            #"{"error":{"param":"response_format","message":"response_format is not supported by this reasoning model"}}"#, "reasoning_effort"))
        #expect(!OpenAICompatibleBackend.namesParameter("response_format is not supported by this reasoning model", "reasoning_effort"))
        #expect(OpenAICompatibleBackend.namesParameter("Invalid reasoning effort", "reasoning_effort"))
    }

    @Test func storedSettingsGainPerTaskThinking() throws {
        // Before thinking was per task: no `reasoning`, one Codex effort.
        let config = try JSONDecoder().decode(BackendConfig.self, from: Data(#"""
        {"id":"lmstudio","name":"LM Studio","type":"openAICompatible","preset":"lmStudio","openAI":{"baseURL":"http://localhost:1234/v1"}}
        """#.utf8))
        #expect(config.reasoning == .local)
        var hosted = BackendConfig.openAI(.openRouter)
        #expect(hosted.reasoning == .modelDefault)
        hosted.reasoning.explain = "high"
        #expect(hosted.openAI?.reasoning == ReasoningSettings(translate: "", explain: "high"))

        let codex = try JSONDecoder().decode(CodexSettings.self, from: Data(#"{"effort":"medium"}"#.utf8))
        #expect(codex.effort == "medium" && codex.explainEffort == "medium")
        #expect(CodexSettings().explainEffort == "low")
    }
}

@Suite struct LocalModelCatalogTests {
    @Test func bundledCopyMatchesTheRepo() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../models.json")
        let file = try JSONDecoder().decode(LocalModelCatalog.self, from: Data(contentsOf: url))
        #expect(file == LocalModelCatalog.bundled)
    }

    @Test func recommendsByMemoryAndDisk() {
        let small = RecommendedModel(id: "a/small", name: "Small", huggingFace: "a/small", minMemoryGB: 16, downloadGB: 5, vision: true, note: "")
        let big = RecommendedModel(id: "a/big", name: "Big", huggingFace: "a/big", minMemoryGB: 32, downloadGB: 12, vision: true, note: "")
        let catalog = LocalModelCatalog(version: 1, models: [small, big])
        let gb: (Double) -> UInt64 = { UInt64($0 * 1_073_741_824) }
        #expect(catalog.recommendation(memoryBytes: gb(8), freeDiskBytes: nil) == nil)
        #expect(catalog.recommendation(memoryBytes: gb(16), freeDiskBytes: nil) == small)
        #expect(catalog.recommendation(memoryBytes: gb(48), freeDiskBytes: nil) == big)
        #expect(catalog.recommendation(memoryBytes: gb(48), freeDiskBytes: 10_000_000_000) == small, "the big one doesn't fit on disk")
        #expect(catalog.recommendation(memoryBytes: gb(48), freeDiskBytes: 3_000_000_000) == nil)
    }
}

@Suite(.serialized) struct LocalModelTests {
    static func backend(_ base: String, preset: OpenAIPreset = .lmStudio, model: String = "", timeLimit: Int? = nil) -> OpenAICompatibleBackend {
        var config = BackendConfig.openAI(preset)
        config.openAI = OpenAISettings(baseURL: base)
        config.openAI?.model = model
        var backend = OpenAICompatibleBackend(config: config)
        backend.timeLimit = timeLimit
        return backend
    }

    @Test func turnsThinkingOffAndLeavesSamplingToTheModel() async throws {
        let (server, base) = try await FakeLMStudio.start()
        defer { server.terminate() }
        _ = try await Self.backend(base).complete(AIRequest(system: "readingCorrections", user: "今天", schema: Prompts.learnSchema))
        _ = try await Self.backend(base).complete(Prompts.explain(text: "今天", translation: nil, context: "", terms: []))
        _ = try await Self.backend(base, model: "fake-plain").complete(AIRequest(system: "readingCorrections", user: "今天"))
        let log = try await FakeLMStudio.log(base)
        #expect(log.allSatisfy { $0["temperature"]?.isNull ?? true }, "no sampling settings: \(log)")
        #expect(log[0]["reasoning_effort"]?.string == "none")
        #expect(log[1]["reasoning_effort"]?.string == "none", "Explain's low thinking becomes off on an on/off model")
        #expect(log[0]["max_tokens"]?.number != nil, "a model that won't think gets a cap")
        #expect(log[2]["reasoning_effort"]?.isNull ?? true, "a model that can't think isn't told how much to")
        #expect(log[2]["max_tokens"]?.number != nil)
        #expect(Self.backend(base).readingMode == .choose, "local models choose among the dictionary's readings by default")
    }

    @Test func hostedBackendsKeepTheirModelsDefault() async throws {
        let (server, base) = try await FakeLMStudio.start()
        defer { server.terminate() }
        _ = try await Self.backend(base, preset: .other).complete(AIRequest(system: "readingCorrections", user: "今天"))
        let log = try await FakeLMStudio.log(base)
        #expect(log[0]["reasoning_effort"]?.isNull ?? true)
        #expect(log[0]["max_tokens"]?.isNull ?? true, "a model that may think gets no cap")
    }

    @Test func retriesWithoutReasoningWhenRejected() async throws {
        let (server, base) = try await FakeLMStudio.start(["--reject-reasoning"])
        defer { server.terminate() }
        let reply = try await Self.backend(base).complete(AIRequest(system: "readingCorrections", user: "今天", schema: Prompts.learnSchema))
        #expect(try Prompts.parseLearn(reply).translation.hasPrefix("[local]"))
        let log = try await FakeLMStudio.log(base)
        #expect(log.map { $0["reasoning_effort"]?.string } == ["none", nil])
        #expect(log.last?["schema"]?.bool == true, "the schema is kept")
    }

    @Test func stopsAReplyThatRepeats() async throws {
        let (server, base) = try await FakeLMStudio.start()
        defer { server.terminate() }
        await #expect(throws: BackendError.repeating(name: "LM Studio · fake-vlm")) {
            _ = try await Self.backend(base).complete(AIRequest(system: "LOOP", user: "x"))
        }
    }

    @Test func saysWhenTheModelThinks() async throws {
        let (server, base) = try await FakeLMStudio.start()
        defer { server.terminate() }
        let thought = Flag()
        var request = AIRequest(system: "THINK", user: "x")
        request.onThinking = { await thought.set() }
        #expect(try await Self.backend(base).complete(request) == "Hello, world", "thinking isn't part of the reply")
        #expect(await thought.value)
    }

    @Test func givesUpAtTheTimeLimit() async throws {
        let (server, base) = try await FakeLMStudio.start()
        defer { server.terminate() }
        let started = Date()
        await #expect(throws: BackendError.timedOut(name: "LM Studio", seconds: 1)) {
            _ = try await Self.backend(base, timeLimit: 1).complete(AIRequest(system: "SLOW", user: "x"))
        }
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test func downloadsAndLoadsModels() async throws {
        let (server, base) = try await FakeLMStudio.start()
        defer { server.terminate() }
        #expect(try await LMStudio.startDownload("fake-vlm", baseURL: base) == nil, "already downloaded")
        let job = try #require(try await LMStudio.startDownload("google/gemma-4-e4b", baseURL: base))
        let first = try await LMStudio.download(job, baseURL: base)
        #expect(first.state == .downloading && first.fraction > 0.3 && first.fraction < 0.7)
        _ = try await LMStudio.download(job, baseURL: base)
        #expect(try await LMStudio.download(job, baseURL: base).state == .completed)
        try await LMStudio.load("google/gemma-4-e4b", baseURL: base)
    }

    @Test func reportsAModelTooBigToLoad() async throws {
        let (server, base) = try await FakeLMStudio.start(["--no-memory"])
        defer { server.terminate() }
        do {
            try await LMStudio.load("google/gemma-4-e4b", baseURL: base)
            Issue.record("loaded")
        } catch {
            #expect(LMStudio.isOutOfMemory(error))
        }
    }

    @Test func fallsBackToTheOldModelList() async throws {
        let (server, base) = try await FakeLMStudio.start(["--v0-only"])
        defer { server.terminate() }
        #expect(try await LMStudio.models(baseURL: base).map(\.id) == ["fake-vlm"])
        await #expect(throws: BackendError.http(status: 404, body: "Unexpected endpoint or method.")) {
            _ = try await LMStudio.startDownload("google/gemma-4-e4b", baseURL: base)
        }
    }

    @Test func leavesThinkingAloneWhenLMStudioDoesNotSay() async throws {
        let (server, base) = try await FakeLMStudio.start(["--v0-only"])
        defer { server.terminate() }
        let models = try await LMStudio.models(baseURL: base)
        #expect(models.first?.canThink == nil)
        _ = try await Self.backend(base).complete(AIRequest(system: "readingCorrections", user: "今天"))
        let log = try await FakeLMStudio.log(base)
        #expect(log[0]["reasoning_effort"]?.string == "none", "the setting is still sent")
        #expect(log[0]["max_tokens"]?.isNull ?? true, "but no cap, since the model may think anyway")
    }

    @Test func readsErrorsSentWithStatus200() async throws {
        let (server, base) = try await FakeLMStudio.start(["--old-200"])
        defer { server.terminate() }
        #expect(try await LMStudio.models(baseURL: base).map(\.id) == ["fake-vlm"])
        await #expect(throws: BackendError.http(status: 404, body: "Unexpected endpoint or method.")) {
            _ = try await LMStudio.startDownload("google/gemma-4-e4b", baseURL: base)
        }
        await #expect(throws: BackendError.self) { try await LMStudio.load("google/gemma-4-e4b", baseURL: base) }
    }

    @Test func reportsAVanishedDownload() async throws {
        let (server, base) = try await FakeLMStudio.start()
        defer { server.terminate() }
        await #expect(throws: BackendError.http(status: 404, body: "No download job job_gone")) {
            _ = try await LMStudio.download("job_gone", baseURL: base)
        }
    }

    @Test func saysWhenAReplyIsCutOff() async throws {
        let (server, base) = try await FakeLMStudio.start()
        defer { server.terminate() }
        await #expect(throws: BackendError.cutOff(name: "LM Studio · fake-vlm")) {
            _ = try await Self.backend(base).complete(AIRequest(system: "LENGTH", user: "x"))
        }
    }

    @Test func givesUpOnAReplyThatNeverEnds() async throws {
        let (server, base) = try await FakeLMStudio.start()
        defer { server.terminate() }
        let started = Date()
        await #expect(throws: BackendError.timedOut(name: "LM Studio", seconds: 1)) {
            _ = try await Self.backend(base, timeLimit: 1).complete(AIRequest(system: "TRICKLE", user: "x"))
        }
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test func deepLinksToLMStudio() {
        #expect(LMStudio.deepLink(huggingFaceRepo: "lmstudio-community/gemma-4-E4B-it-MLX-4bit")?.absoluteString
                == "lmstudio://open_from_hf?model=lmstudio-community/gemma-4-E4B-it-MLX-4bit")
    }
}

private actor Flag {
    var value = false
    func set() { value = true }
}

@Suite struct FencedReplyTests {
    @Test func dropsAMarkdownFenceAroundAnExplanation() {
        #expect(Prompts.unfenced("```markdown\n**Structure**: A + B\n```") == "**Structure**: A + B")
        #expect(Prompts.unfenced("```markdown\n**Structure**: A + B\n- still coming") == "**Structure**: A + B\n- still coming")
        #expect(Prompts.unfenced("```\n**Structure**\n```") == "**Structure**")
        #expect(Prompts.unfenced("**Part 1 of 2**\n\n```markdown\n- one\n```\n\n---\n\n**Part 2 of 2**\n\n```markdown\n- two")
                == "**Part 1 of 2**\n\n- one\n\n---\n\n**Part 2 of 2**\n\n- two")
    }

    @Test func keepsCodeBlocksAndTranscriptions() {
        let withCode = "Use it like this:\n```swift\nprint(1)\n```"
        #expect(Prompts.unfenced(withCode) == withCode)
        let example = "**Words**: a heading looks like this:\n```markdown\n# 标题\n```"
        #expect(Prompts.unfenced(example) == example, "a Markdown example inside the Explanation stays")
        let transcription = "```markdown\n# 标题\n```"
        #expect(Prompts.visibleText(transcription) == transcription, "reading an image keeps every line")
        #expect(try! Prompts.parseReverse("```json\n{\"chinese\": \"你好\", \"note\": \"\"}\n```").chinese == "你好")
    }
}
