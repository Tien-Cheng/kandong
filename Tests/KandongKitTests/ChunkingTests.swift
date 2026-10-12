import Foundation
import Testing
@testable import KandongKit

@Suite struct TextChunkerTests {
    @Test func splitsChineseAndEnglishSentences() {
        let text = "你好！今天天气很好。他说：“走吧。”Ready? Pi is 3.14. Done\n下一行"
        let sentences = TextChunker.sentences(text)
        #expect(sentences == ["你好！", "今天天气很好。", "他说：“走吧。”", "Ready? ", "Pi is 3.14. ", "Done\n", "下一行"])
        #expect(sentences.joined() == text)
    }

    @Test func fallsBackToClausesThenHalves() {
        #expect(TextChunker.smaller("我们先去吃饭，然后看电影、再回家") == ["我们先去吃饭，", "然后看电影、", "再回家"])
        #expect(TextChunker.smaller("一二三四") == ["一二", "三四"])
        #expect(TextChunker.smaller("一") == ["一"])
    }

    @Test func packsTheLargestPiecesThatFit() async {
        let units = ["aaa", "bb", "cccc", "d", "ee"]
        let pieces = await TextChunker.pack(units) { piece, _ in piece.count <= 6 }
        #expect(pieces?.map(\.text) == ["aaabb", "ccccd", "ee"])
        #expect(pieces?.map(\.preceding) == [nil, "bb", "d"])
    }

    @Test func packBreaksUpAUnitThatIsTooLongAlone() async {
        let pieces = await TextChunker.pack(["一二三四五六，七八", "九"]) { piece, _ in piece.count <= 6 }
        #expect(pieces?.map(\.text).joined() == "一二三四五六，七八九")
        #expect(pieces?.allSatisfy { $0.text.count <= 6 } == true)
    }

    @Test func neverSplitsURLsOrWords() {
        #expect(TextChunker.halves("https://example.com/a") == ["https://example.com/a"])
        #expect(TextChunker.halves("你好你好https://example.com").joined() == "你好你好https://example.com")
        #expect(TextChunker.halves("你好你好https://example.com").last == "https://example.com")
        #expect(TextChunker.sentences("看这个https://a.com/?q=1 好吗？对。") == ["看这个https://a.com/?q=1 好吗？", "对。"])
        #expect(TextChunker.clauses("见https://a.com/x,y 好，走") == ["见https://a.com/x,y 好，", "走"])
        #expect(TextChunker.sentences("你好?我很好") == ["你好?", "我很好"])
    }

    @Test func packGivesUpWhenNothingFits() async {
        #expect(await TextChunker.pack(["一二"]) { _, _ in false } == nil)
    }
}

/// Stand-in translations: Chinese characters become "h"; English letters become 汉.
private func fakeEnglish(_ text: String) -> String { String(text.map { $0.isHan ? "h" : $0 }) }
private func fakeChinese(_ text: String) -> String { String(text.map { $0.isASCII && $0.isLetter ? "汉" : $0 }) }

/// "Translates" the text it was given, failing anything longer than `limit` characters of prompt.
private final class FakeBackend: AIBackend, @unchecked Sendable {
    let kind = BackendKind.custom
    let label = "Fake"
    let limit: Int
    let measures: Bool
    /// Claims everything fits, like an estimate that turns out wrong.
    var overconfident = false
    private let lock = NSLock()
    private var sent: [AIRequest] = []

    init(limit: Int, measures: Bool) {
        self.limit = limit
        self.measures = measures
    }

    var requests: [AIRequest] { lock.withLock { sent } }

    func supportsImages() async -> Bool { false }

    func fits(_ request: AIRequest) async -> Bool? {
        overconfident ? true : measures ? request.user.count <= limit : nil
    }

    func respond(to request: AIRequest) -> AsyncThrowingStream<String, Error> {
        lock.withLock { sent.append(request) }
        return AsyncThrowingStream { continuation in
            guard request.user.count <= limit else { return continuation.finish(throwing: BackendError.contextTooLong) }
            let marker = request.user.range(of: "Text:\n") ?? request.user.range(of: "English:\n")!
            var text = String(request.user[marker.upperBound...])
            if let readings = text.range(of: "\n\nDictionary pinyin:") { text = String(text[..<readings.lowerBound]) }
            let reverse = marker.lowerBound == request.user.range(of: "English:\n")?.lowerBound
            let reply: JSONValue = reverse ? ["chinese": .string(fakeChinese(text)), "note": ""] : ["translation": .string(fakeEnglish(text)), "readingCorrections": []]
            continuation.yield(String(data: try! reply.encoded(), encoding: .utf8)!)
            continuation.finish()
        }
    }
}

/// Gives English back unchanged as its "Chinese".
private struct EchoBackend: AIBackend {
    let kind = BackendKind.custom
    let label = "Echo"
    func supportsImages() async -> Bool { false }
    func respond(to request: AIRequest) -> AsyncThrowingStream<String, Error> {
        let text = String(request.user[request.user.range(of: "English:\n")!.upperBound...])
        return AsyncThrowingStream { continuation in
            continuation.yield(String(data: try! JSONValue.object(["chinese": .string(text), "note": ""]).encoded(), encoding: .utf8)!)
            continuation.finish()
        }
    }
}

/// Copies any text longer than one sentence back untranslated; translates single sentences.
private struct EchoOnceBackend: AIBackend {
    let kind = BackendKind.custom
    let label = "Echo"
    func supportsImages() async -> Bool { false }

    func respond(to request: AIRequest) -> AsyncThrowingStream<String, Error> {
        let text = String(request.user[request.user.range(of: "Text:\n")!.upperBound...])
            .components(separatedBy: "\n\nDictionary pinyin:")[0]
        let sentences = TextChunker.sentences(text).count
        let translation = sentences > 1 ? text : String(repeating: "ab", count: text.filter(\.isHan).count)
        return AsyncThrowingStream { continuation in
            continuation.yield(#"{"translation": "\#(translation)", "readingCorrections": []}"#)
            continuation.finish()
        }
    }
}

@Suite(.enabled(if: TestData.hasDictionary, "run scripts/fetch-data.sh"))
struct ChunkingTests {
    static let sentences = (1...12).map { "第\($0)句话说的是今天下午我们一起去图书馆看书。" }

    func engine(context: String = "", terms: [Term] = []) throws -> LookupEngine {
        let workspace = Workspace(folder: FileManager.default.temporaryDirectory.appendingPathComponent("kandong-chunk-\(UUID().uuidString)"))
        try workspace.ensureExists()
        try context.write(to: workspace.contextURL, atomically: true, encoding: .utf8)
        try workspace.saveTerms(terms)
        return LookupEngine(analyzer: TestData.analyzer!, workspace: workspace)
    }

    @Test func shortTextIsSentWhole() async throws {
        let backend = FakeBackend(limit: 2000, measures: true)
        let engine = try engine()
        let (translation, _) = try await engine.learn(engine.offline("今天下午三点上中文课。"), backend: backend)
        #expect(translation == fakeEnglish("今天下午三点上中文课。"))
        #expect(backend.requests.count == 1)
        #expect(backend.requests[0].user.contains("Dictionary pinyin"))
    }

    @Test(arguments: [true, false])
    func dropsReadingsBeforeSplitting(measures: Bool) async throws {
        let text = Self.sentences.prefix(3).joined()
        let backend = FakeBackend(limit: text.count + 40, measures: measures)
        let engine = try engine()
        let (translation, _) = try await engine.learn(engine.offline(text), backend: backend)
        #expect(translation == fakeEnglish(text))
        let last = try #require(backend.requests.last)
        #expect(!last.user.contains("Dictionary pinyin"))
        #expect(last.user.contains(text))
    }

    @Test func trimsContextBeforeSplitting() async throws {
        let context = String(repeating: "I read a lot of Chinese news about technology and business.\n", count: 12)
        let text = Self.sentences[0]
        let backend = FakeBackend(limit: text.count + 520, measures: true)
        let engine = try engine(context: context)
        let (translation, _) = try await engine.learn(engine.offline(text), backend: backend)
        #expect(translation == fakeEnglish(text))
        #expect(backend.requests.count == 1)
        #expect(backend.requests[0].user.contains(" …"))
    }

    @Test(arguments: [true, false])
    func splitsLongTextIntoParts(measures: Bool) async throws {
        let text = Self.sentences.joined()
        let backend = FakeBackend(limit: 200, measures: measures)
        let engine = try engine(terms: [Term(chinese: "第12句", english: "line twelve")])
        let events = ProgressLog()
        let (translation, _) = try await engine.learn(engine.offline(text), backend: backend) { await events.add($0) }

        let parts = backend.requests.filter { $0.user.count <= 200 }
        #expect(parts.count > 1)
        // Parts are joined with a space.
        #expect(translation.replacingOccurrences(of: " ", with: "") == fakeEnglish(text))
        #expect(translation.filter { $0 == " " }.count == parts.count - 1)
        #expect(parts.dropFirst().allSatisfy { $0.user.contains("Preceding text") })
        // Terms go only with the part that contains them.
        #expect(parts.filter { $0.user.contains("line twelve") }.count == 1)
        #expect(await events.last?.completedParts == parts.count)
        if measures {
            // Every part is as large as allowed: no two neighbours would have fitted together.
            #expect(parts.count == backend.requests.count)
        }
    }

    @Test func recoversWhenAPartFitsOnPaperButNotInPractice() async throws {
        let text = Self.sentences.joined()
        let backend = FakeBackend(limit: 200, measures: true)
        backend.overconfident = true
        let engine = try engine()
        let (translation, _) = try await engine.learn(engine.offline(text), backend: backend)
        #expect(translation.replacingOccurrences(of: " ", with: "") == fakeEnglish(text))
    }

    @Test func reverseKeepsPassThroughParts() async throws {
        let engine = try engine()
        let (reply, _) = try await engine.reverse("123 @bob https://example.com", backend: EchoBackend())
        #expect(reply.chinese == "123 @bob https://example.com")
    }

    @Test func reverseJoinsChineseParts() async throws {
        let english = (1...10).map { "Sentence number \($0) is about going to the library this afternoon. " }.joined()
        let backend = FakeBackend(limit: 250, measures: true)
        let engine = try engine()
        let (reply, _) = try await engine.reverse(english, backend: backend)
        #expect(backend.requests.count > 1)
        // Chinese parts are joined with nothing between them.
        #expect(reply.chinese.filter { !$0.isWhitespace } == fakeChinese(english).filter { !$0.isWhitespace })
    }

    @Test func retriesAPartThatCameBackUntranslated() async throws {
        let text = Self.sentences.prefix(4).joined()
        let backend = EchoOnceBackend()
        let engine = try engine()
        let (translation, _) = try await engine.learn(engine.offline(text), backend: backend)
        #expect(translation.split(separator: " ").count == 4)
        #expect(!LookupEngine.isUntranslated(english: translation, source: text))
    }

    @Test func spotsUntranslatedReplies() {
        let diary = "第80天，我和小王一起去香山爬山。"
        #expect(LookupEngine.isUntranslated(english: diary, source: diary))
        #expect(LookupEngine.isUntranslated(english: "第80天,我和小王一起去香山爬山.", source: diary))
        #expect(!LookupEngine.isUntranslated(english: "Day 80: I went hiking at Xiangshan (香山) with Xiao Wang.", source: diary))
        // Quoting a sign inside a real translation is fine.
        let sign = "牌子上写着“禁止停车请勿占用消防通道”"
        #expect(!LookupEngine.isUntranslated(english: "The sign says “禁止停车请勿占用消防通道” (no parking, keep the fire lane clear).", source: sign))
        // Copied mixed text is caught when enough Chinese is left untranslated.
        let mixed = "今天的会议改到明天下午了. The agenda stays the same."
        #expect(LookupEngine.isUntranslated(english: mixed, source: mixed))
        #expect(!LookupEngine.isUntranslated(english: "你好", source: "你好"))
        // A summary of a long text is caught; a full translation of it isn't.
        let long = String(repeating: "今天下午我们一起去图书馆看书。", count: 3)
        #expect(LookupEngine.isUntranslated(english: "We read books.", source: long))
        #expect(!LookupEngine.isUntranslated(english: String(repeating: "This afternoon we went to the library to read. ", count: 3), source: long))
    }

    @Test func knowsWhatEnglishNeedsTranslating() {
        #expect(!LookupEngine.needsTranslation(english: "123 @bob #tag https://example.com www.a.com"))
        #expect(LookupEngine.needsTranslation(english: "See you @bob"))
    }

    @Test func explanationPartsSplitUntilTheyCannot() {
        var parts = ExplanationParts(["一。二。三。四。"])
        var split = parts.splitCurrent()
        #expect(split)
        #expect(parts.parts == ["一。二。", "三。四。"])
        parts.finishCurrent()
        #expect(parts.current == "三。四。")
        split = parts.splitCurrent()
        #expect(split)
        #expect(parts.parts == ["一。二。", "三。", "四。"])
        // "三。" halves into "三" and "。"; a single character can't get smaller.
        while parts.splitCurrent() {}
        #expect(parts.current?.count == 1)

        var single = ExplanationParts(["一"])
        split = single.splitCurrent()
        #expect(!split)
        #expect(single.parts == ["一"])
        var url = ExplanationParts(["https://example.com"])
        split = url.splitCurrent()
        #expect(!split)
    }

    @Test func keepsLineBreaksBetweenParts() {
        let joined = LookupEngine.join([("一。\n", "One."), ("二。", "Two.")], separator: " ")
        #expect(joined == "One.\nTwo.")
    }

    @Test func explainsLongTextInParts() async throws {
        let text = Self.sentences.joined()
        let engine = try engine()
        let parts = await engine.explanationParts(text, translation: nil, backend: FakeBackend(limit: 150, measures: true))
        #expect(parts.count > 1)
        #expect(parts.parts.joined() == text)
        #expect(await engine.explanationParts("你好。", translation: nil, backend: FakeBackend(limit: 4000, measures: true)).parts == ["你好。"])
    }
}

private actor ProgressLog {
    var events: [LookupProgress] = []
    var last: LookupProgress? { events.last }
    func add(_ event: LookupProgress) { events.append(event) }
}

/// A long article through the on-device model. Opt in: `KANDONG_LIVE=1 swift test --filter LiveChunkingTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KANDONG_LIVE"] == "1" && TestData.hasDictionary
    && AppleIntelligenceBackend.unavailability == nil))
struct LiveChunkingTests {
    static let people = ["小王", "李老师", "我妹妹", "张经理", "老陈", "我的室友", "隔壁的阿姨", "小刘"]
    static let places = ["香山", "长城", "西湖", "黄山", "泰山", "公园", "海边", "图书馆"]
    static let activities = ["爬山", "散步", "拍照", "野餐", "骑自行车", "看日出", "钓鱼", "写生"]

    /// About 7,800 characters of varied diary entries.
    static var article: String {
        (1...80).map { day in
            let person = people[day % people.count], place = places[(day * 3) % places.count]
            let activity = activities[(day * 5) % activities.count]
            return "第\(day)天，我和\(person)一起去\(place)\(activity)。我们早上\(day % 5 + 6)点出发，路上花了\(day % 3 + 1)个小时。" +
                "那天的天气\(day % 2 == 0 ? "很好，阳光明媚" : "不太好，一直在下小雨")，可是大家的心情都不错。" +
                "\(person)说这是\(day % 4 + 2)年来第一次来这里，觉得很新鲜。回家以后我写了这篇日记。\n"
        }.joined()
    }

    @Test func translatesALongArticleInParts() async throws {
        let text = Self.article
        let workspace = Workspace(folder: FileManager.default.temporaryDirectory.appendingPathComponent("kandong-live-\(UUID().uuidString)"))
        try workspace.ensureExists()
        let engine = LookupEngine(analyzer: TestData.analyzer!, workspace: workspace)
        let events = ProgressLog()
        let started = Date()
        let (translation, _) = try await engine.learn(engine.offline(text), backend: AppleIntelligenceBackend()) { await events.add($0) }
        let total = await events.last?.totalParts ?? 1
        print("\(text.count) characters → \(total) parts, \(translation.count) characters of English in \(Int(Date().timeIntervalSince(started)))s")
        var previous = 0
        for event in await events.events where event.translation.count != previous {
            print("after \(event.completedParts) parts: +\(event.translation.count - previous) characters")
            previous = event.translation.count
        }
        for event in await events.events { print("progress: \(event.completedParts)/\(event.totalParts ?? 0) → \(event.translation.count) chars") }
        let pattern = try Regex(#"[Dd]ay (\d+)|(\d+)(?:st|nd|rd|th) day"#)
        let days = Set(translation.matches(of: pattern).compactMap { match in
            (match.output[1].substring ?? match.output[2].substring).flatMap { Int($0) }
        })
        print("days mentioned: \(days.count) of 80; missing: \(Set(1...80).subtracting(days).sorted())")
        print("tail: \(translation.suffix(300))")
        #expect(total > 1)
        #expect(!LookupEngine.isUntranslated(english: translation, source: text))
        // Every day's entry made it into the English.
        #expect(days.count >= 76)
    }
}
