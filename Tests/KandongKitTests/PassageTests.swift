import Foundation
import SQLite3
import Testing
@testable import KandongKit

private let sentence = "今天天气很好，我们去公园散步。"   // 15 characters

@Suite struct PassageSplitTests {
    @Test func shortTextIsShownWhole() {
        #expect(Passage.split("你好。\n再见。").isEmpty)
        #expect(Passage.split(String(repeating: sentence, count: 8)).isEmpty)
        // English says less per letter.
        #expect(Passage.split(String(repeating: "We went for a walk. ", count: 10)).isEmpty)
    }

    @Test func oneParagraphEach() {
        let first = String(repeating: sentence, count: 5), second = String(repeating: sentence, count: 6)
        let passages = Passage.split(first + "\n\n" + second + "\n" + sentence)
        #expect(passages.map(\.text) == [first, second, sentence])
        #expect(passages.map(\.leading) == ["", "\n\n", "\n"])
        #expect(passages.allSatisfy { $0.startsParagraph })
        #expect(passages.map(\.id) == [0, 1, 2])
    }

    @Test func longParagraphsAreCutAtSentenceEnds() {
        let passages = Passage.split(String(repeating: sentence, count: 20))
        #expect(passages.count == 3)
        #expect(passages.allSatisfy { $0.text.hasSuffix("。") && Passage.weight($0.text) <= Passage.limit })
        #expect(passages.map(\.startsParagraph) == [true, false, false])
        #expect(passages.map(\.text).joined() == String(repeating: sentence, count: 20))
    }

    @Test func endlessSentencesAreCutAtClauses() {
        let passages = Passage.split(String(repeating: "我们去公园散步，", count: 60))
        #expect(passages.count > 2)
        #expect(passages.allSatisfy { Passage.weight($0.text) <= Passage.limit })
        // Nothing to cut at: still no enormous passage.
        #expect(Passage.split(String(repeating: "字", count: 900)).allSatisfy { Passage.weight($0.text) <= Passage.limit })
    }

    @Test func aShortTailStaysWithItsParagraph() {
        let passages = Passage.split(String(repeating: sentence, count: 10) + "好。")
        #expect(passages.isEmpty || passages.allSatisfy { Passage.weight($0.text) >= 30 })
    }

    @Test func rejoinsLinesAScreenshotWrapped() {
        // Wrapped every 20 characters, through words and sentences.
        let text = String(repeating: "昨天我和朋友一起去了新开的图书馆看书然后喝了咖啡，", count: 6)
        let characters = Array(text)
        let wrapped = stride(from: 0, to: characters.count, by: 20).map { String(characters[$0..<min($0 + 20, characters.count)]) }.joined(separator: "\n")
        let paragraphs = Passage.paragraphs(wrapped)
        #expect(paragraphs.map(\.text) == [text])
        #expect(Passage.paragraphs("this line of English was wrapped by the\nPDF it came from and it carries on over\nthree lines").map(\.text)
            == ["this line of English was wrapped by the PDF it came from and it carries on over three lines"])
    }

    @Test func keepsChatListsAndPoemsApart() {
        let chat = "在吗\n晚上一起吃火锅不\n好啊几点"
        #expect(Passage.paragraphs(chat).map(\.text) == ["在吗", "晚上一起吃火锅不", "好啊几点"])
        let poem = "床前明月光\n疑是地上霜\n举头望明月\n低头思故乡"
        #expect(Passage.paragraphs(poem).count == 4)
        let list = "1. 第一件事情是明天上午要去超市买很多东西回来\n2. 第二件事情是下午要给妈妈打一个很长的电话\n3. 第三件事情是晚上要把作业全部做完再去睡觉"
        #expect(Passage.paragraphs(list).count == 3)
        let sentences = "这一行本身就是一个完整的句子而且还挺长的。\n这一行也是一个完整的句子而且同样也挺长的。\n最后一行同样是一个完整的句子所以不应该合并。"
        #expect(Passage.paragraphs(sentences).count == 3)
        #expect(Passage.paragraphs("\u{3000}\u{3000}这一段开头有全角空格所以是一个新的段落的开始\n\u{3000}\u{3000}这一段开头也有全角空格所以又是一个新的段落\n\u{3000}\u{3000}最后这一段").count == 3)
    }

    @Test func joiningKeepsParagraphs() {
        let text = String(repeating: sentence, count: 20) + "\n\n" + sentence + "\n" + sentence
        let passages = Passage.split(text)
        #expect(Passage.join(passages) { $0.text } == text)
        let joined = Passage.join(passages, spaced: true) { "P\($0.id)." }
        #expect(joined == "P0. P1. P2.\n\nP3.\nP4.")
        // One that couldn't be translated leaves no gap.
        #expect(Passage.join(passages, spaced: true) { $0.id == 1 ? "" : "P\($0.id)." } == "P0. P2.\n\nP3.\nP4.")
    }
}

@Suite struct PassageJSONTests {
    @Test func readsEveryPassageSoFar() {
        let text = #"{"passages": {"p01": "One, \"quoted\".", "p02": "Tw"#
        let values = PartialJSON.stringValues(inObject: "passages", in: text)
        #expect(values.map(\.key) == ["p01", "p02"])
        #expect(values.map(\.value) == ["One, \"quoted\".", "Tw"])
        #expect(values.map(\.isComplete) == [true, false])
        #expect(PartialJSON.stringValues(inObject: "passages", in: #"{"passages": {"p0"#).isEmpty)
        #expect(PartialJSON.stringValues(inObject: "passages", in: #"{"passages": "#).isEmpty)
        #expect(PartialJSON.stringValues(inObject: "passages", in: #"{"passages": "none"}"#).isEmpty)
        #expect(PartialJSON.stringValues(inObject: "passages", in: #"{"passages": {"p01": "a"}, "readings": {"w1": "hái"}}"#).map(\.key) == ["p01"])
    }

    @Test func keysSortInOrder() {
        let passages = (0..<120).map { Passage(id: $0, text: "", leading: "") }
        let keys = passages.map { Prompts.key(of: $0, count: 120) }
        #expect(keys == keys.sorted())
        #expect(Prompts.key(of: passages[0], count: 9) == "p01")
        // Apple's partial replies list their keys in no order: the latest passage is the unfinished one.
        #expect(keys.shuffled().max() == "p120")
        #expect(keys.first == "p001" && keys.last == "p120")
        #expect(Prompts.passagesKey(.learn) < "readings" && Prompts.passagesKey(.reverse) < "note")
    }
}

/// Translates passages, with one habit that goes wrong.
private final class PassageBackend: AIBackend, @unchecked Sendable {
    enum Habit { case none, drops(Set<String>), dropsOnce(Set<String>), copies(String), cutsOffAfter(Int), unreachableAfter(Int), refuses(String) }

    let label = "Passages"
    let readingMode: ReadingMode
    let habit: Habit
    let limit: Int?
    let measures: Bool
    private let lock = NSLock()
    private var sent: [AIRequest] = []

    init(_ habit: Habit = .none, limit: Int? = nil, measures: Bool = false, readingMode: ReadingMode = .off) {
        self.habit = habit
        self.limit = limit
        self.measures = measures
        self.readingMode = readingMode
    }

    var requests: [AIRequest] { lock.withLock { sent } }

    func supportsImages() async -> Bool { false }
    func fits(_ request: AIRequest) async -> Bool? {
        guard measures, let limit else { return nil }
        return request.user.count <= limit
    }

    func respond(to request: AIRequest) -> AsyncThrowingStream<String, Error> {
        let earlier = lock.withLock { sent.append(request); return sent.count - 1 }
        return AsyncThrowingStream { continuation in
            if let limit, request.user.count > limit { return continuation.finish(throwing: BackendError.contextTooLong) }
            if case .unreachableAfter(let count) = habit, earlier >= count {
                return continuation.finish(throwing: BackendError.serverUnavailable(name: "Server", url: "", hint: ""))
            }
            let pattern = #/\[(p\d+)\] ([^\n]*)/#
            let found = request.user.matches(of: pattern).map { (key: String($0.1), text: String($0.2)) }
            guard !found.isEmpty else {
                // A single passage, asked the ordinary way.
                let text = request.user.components(separatedBy: "Text:\n").last ?? ""
                continuation.yield(#"{"translation": "\#(String(repeating: "word ", count: text.count / 2))"}"#)
                return continuation.finish()
            }
            if case .refuses(let key) = habit, found.contains(where: { $0.key == key }) {
                return continuation.finish(throwing: BackendError.refused(name: "Passages"))
            }
            var parts: [String] = []
            for (key, text) in found {
                switch habit {
                case .drops(let keys) where keys.contains(key): continue
                case .dropsOnce(let keys) where earlier == 0 && keys.contains(key): continue
                case .copies(let copied) where copied == key: parts.append(#""\#(key)": "\#(text)""#)
                default:
                    let reply = text.containsHan ? "[\(key)] " + String(repeating: "word ", count: text.count / 2) : "汉字" + key
                    parts.append(#""\#(key)": "\#(reply)""#)
                }
            }
            let object = request.user.contains("English:\n") ? "chinese" : "passages"
            if case .cutsOffAfter(let count) = habit, parts.count > count {
                continuation.yield(#"{"\#(object)": {"# + parts.prefix(count).joined(separator: ", ") + #", "p99": "half a"#)
                return continuation.finish(throwing: BackendError.cutOff(name: "Passages"))
            }
            continuation.yield(#"{"\#(object)": {"# + parts.joined(separator: ", ") + "}}")
            continuation.finish()
        }
    }
}

private actor Reports {
    var all: [PassageProgress] = []
    func add(_ progress: PassageProgress) { all.append(progress) }
}

@Suite struct PassageTranslationTests {
    private static let text = (0..<8).map { _ in String(repeating: sentence, count: 5) }.joined(separator: "\n")

    private func engine() throws -> LookupEngine {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = Workspace(folder: folder)
        return LookupEngine(analyzer: OfflineAnalyzer(dictionary: CEDict(text: ""), hsk: HSKTable()), workspace: workspace)
    }

    private func translate(_ backend: PassageBackend, progress: PassageHandler? = nil) async throws -> PassageReplies {
        let engine = try engine()
        let analysis = engine.offline(Self.text)
        #expect(analysis.passages.count == 8)
        return try await engine.learnPassages(analysis, wanted: analysis.passages.map(\.passage), backend: backend, progress: progress).replies
    }

    @Test func translatesEveryPassageInOneRequest() async throws {
        let backend = PassageBackend()
        let reports = Reports()
        let replies = try await translate(backend) { await reports.add($0) }
        #expect(backend.requests.count == 1)
        #expect(replies.texts.keys.sorted() == Array(0..<8))
        #expect(replies.error == nil)
        // The mark some models repeat is taken off.
        #expect(replies.texts[0]?.hasPrefix("word") == true)
        #expect(await reports.all.last?.texts.count == 8)
    }

    @Test func asksAgainOnlyForTheOnesLeftOut() async throws {
        let backend = PassageBackend(.dropsOnce(["p03", "p06"]))
        let replies = try await translate(backend)
        #expect(replies.texts.count == 8)
        #expect(backend.requests.count == 2)
        let again = try #require(backend.requests.last).user
        #expect(again.contains("[p03]") && again.contains("[p06]") && !again.contains("[p01]"))
    }

    @Test func keepsTheRestWhenSomeNeverCome() async throws {
        let dropped = try await translate(PassageBackend(.drops(["p02"])))
        #expect(dropped.texts.keys.sorted() == [0, 2, 3, 4, 5, 6, 7])
        #expect(dropped.error == nil)
        let copied = try await translate(PassageBackend(.copies("p05")))
        #expect(copied.texts[4] == nil && copied.texts.count == 7)
    }

    @Test func keepsWhatAnUnfinishedReplyFinished() async throws {
        // Cut off after three: those count, the half-written one doesn't, and the rest are asked again.
        let replies = try await translate(PassageBackend(.cutsOffAfter(4)))
        #expect(replies.texts.count == 8)
        #expect(replies.error == nil)
    }

    @Test func oneRefusedPassageDoesntLoseTheOthers() async throws {
        let replies = try await translate(PassageBackend(.refuses("p02")))
        #expect(replies.texts.keys.sorted() == [4, 5, 6, 7])
        #expect(replies.error as? BackendError == .refused(name: "Passages"))
    }

    @Test func keepsFinishedPassagesWhenTheBackendGoesAway() async throws {
        let backend = PassageBackend(.unreachableAfter(3), limit: 300)
        let replies = try await translate(backend)
        #expect(!replies.texts.isEmpty && replies.texts.count < 8)
        #expect(replies.error is BackendError)
        // It isn't asked again and again.
        #expect(backend.requests.count <= 5)
    }

    @Test(arguments: [true, false]) func sendsWhatFits(measures: Bool) async throws {
        let backend = PassageBackend(limit: 300, measures: measures)
        let replies = try await translate(backend)
        #expect(replies.texts.count == 8)
        #expect(backend.requests.count > 1)
        if measures { #expect(backend.requests.allSatisfy { $0.user.count <= 300 }) }
        // Later batches hear what came before them.
        #expect(backend.requests.contains { $0.user.contains("Preceding text") })
    }

    @Test func translatesOnlyWhatIsWanted() async throws {
        let engine = try engine()
        let analysis = engine.offline(Self.text)
        let backend = PassageBackend()
        let wanted = [analysis.passages[2].passage, analysis.passages[5].passage]
        let replies = try await engine.learnPassages(analysis, wanted: wanted, backend: backend).replies
        #expect(replies.texts.keys.sorted() == [2, 5])
        #expect(backend.requests[0].user.contains("[p03]") && !backend.requests[0].user.contains("[p04]"))
    }

    @Test func saysLongEnglishInChinese() async throws {
        let paragraph = String(repeating: "We went for a walk in the park together. ", count: 6)
        let passages = Passage.split([paragraph, paragraph, paragraph].joined(separator: "\n\n"))
        #expect(passages.count == 3)
        let replies = try await engine().reversePassages(passages, of: passages, backend: PassageBackend())
        #expect(replies.texts.count == 3)
        #expect(replies.texts.values.allSatisfy { $0.containsHan })
    }

    @Test func knowsWhatNeedsNoTranslation() {
        func passage(_ text: String) -> Passage { Passage(id: 0, text: text, leading: "") }
        #expect(!LookupEngine.needsTranslation(passage("https://example.com"), .learn))
        #expect(LookupEngine.needsTranslation(passage("这个 feature"), .learn))
        #expect(!LookupEngine.needsTranslation(passage("你好"), .reverse))
        #expect(LookupEngine.needsTranslation(passage("hello 你好"), .reverse))
    }

    @Test func wordsKeepTheirPassageAndSentence() throws {
        let analysis = try engine().offline(Self.text)
        for passage in analysis.passages {
            let segments = analysis.segments(of: passage)
            #expect(segments.map(\.original).joined() == passage.passage.text)
            #expect(segments.allSatisfy { $0.id / 10_000 == passage.id })
        }
        #expect(Set(analysis.segments.map(\.id)).count == analysis.segments.count)
        let word = try #require(analysis.segments(of: analysis.passages[3]).last { $0.isWord })
        #expect(analysis.passage(containing: word.id)?.id == 3)
        #expect(analysis.sentence(containing: word.id) == sentence)
    }

    @Test func savesOnlyTheSentenceOfShortTextToo() throws {
        let analysis = try engine().offline("你好。我们走吧！再见。")
        #expect(analysis.passages.isEmpty)
        let word = try #require(analysis.words.first { $0.text.contains("走") })
        #expect(analysis.sentence(containing: word.id) == "我们走吧！")
    }

    /// Answers every reading asked about with its last option.
    private struct LastReading: AIBackend {
        let label = "Readings"
        let readingMode = ReadingMode.choose
        func supportsImages() async -> Bool { false }
        func respond(to request: AIRequest) -> AsyncThrowingStream<String, Error> {
            let answers = request.user.matches(of: #/(w\d+) [^:\n]+: .*\| (\S+)/#).map { #""\#($0.1)": "\#($0.2)""# }
            return AsyncThrowingStream { continuation in
                continuation.yield(#"{"readings": {"# + answers.joined(separator: ", ") + "}}")
                continuation.finish()
            }
        }
    }

    @Test func asksForReadingsOnceTranslated() async throws {
        let dictionary = CEDict(text: "还 还 [hai2] /still/\n还 还 [huan2] /to return/\n")
        let engine = LookupEngine(analyzer: OfflineAnalyzer(dictionary: dictionary, hsk: HSKTable()),
                                  workspace: Workspace(folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let paragraph = String(repeating: sentence, count: 2) + "还。"
        let analysis = engine.offline(Array(repeating: paragraph, count: 6).joined(separator: "\n"))
        #expect(analysis.passages.count == 6)
        actor Steps { var all: [OfflineAnalysis] = []; func add(_ step: OfflineAnalysis) { all.append(step) } }
        let steps = Steps()
        // The last one wasn't translated, so it isn't asked about.
        let translations = Dictionary(uniqueKeysWithValues: (0..<5).map { ($0, "English") })
        try await engine.contextReadings(analysis, translations: translations, backend: LastReading()) { await steps.add($0) }
        #expect(await steps.all.count == 2)
        let words = try #require(await steps.all.last).words.filter { $0.text == "还" }
        #expect(words.map(\.readingCorrected) == [true, true, true, true, true, false])
        #expect(words.first?.pinyin == analysis.words.first { $0.text == "还" }?.alternativeReadings.last)
        // Other modes don't ask.
        try await engine.contextReadings(analysis, translations: translations, backend: PassageBackend()) { _ in Issue.record("asked") }
    }

    @Test func readsEachOccurrenceOnItsOwn() throws {
        let dictionary = CEDict(text: "还 还 [hai2] /still/\n还 还 [huan2] /to return/\n")
        let engine = LookupEngine(analyzer: OfflineAnalyzer(dictionary: dictionary, hsk: HSKTable()),
                                  workspace: Workspace(folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let paragraph = String(repeating: sentence, count: 5) + "还。"
        let analysis = engine.offline([paragraph, paragraph].joined(separator: "\n"))
        let choices = ReadingChoice.all(in: analysis)
        #expect(choices.count == 2)
        // Each occurrence is read on its own, across passages.
        let read = engine.applyReadings([choices[1].key: choices[1].options[1]], to: analysis)
        let words = read.words.filter { $0.text == "还" }
        #expect(words.map(\.readingCorrected) == [false, true])
        #expect(read.passages == analysis.passages)
    }
}

@Suite struct PassageHistoryTests {
    @Test func keepsPassages() throws {
        let store = try HistoryStore.inMemory()
        let id = store.record(source: .selection, direction: .learn, text: "长")
        store.setTranslation(id: id, translation: "One. Two.", backend: "B", passages: ["One.", "", "Two."])
        #expect(store.recent().first?.passages == ["One.", "", "Two."])
        let short = store.record(source: .selection, direction: .learn, text: "短", date: Date().addingTimeInterval(5))
        store.setTranslation(id: short, translation: "Short", backend: "B")
        #expect(store.recent().first?.passages == [])
    }

    @Test func opensHistoryFromBeforePassages() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/history.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, """
            CREATE TABLE lookups (id INTEGER PRIMARY KEY AUTOINCREMENT, created_at REAL NOT NULL, source TEXT NOT NULL, direction TEXT NOT NULL,
                text TEXT NOT NULL, translation TEXT NOT NULL DEFAULT '', backend TEXT NOT NULL DEFAULT '');
            INSERT INTO lookups (created_at, source, direction, text, translation) VALUES (1, 'selection', 'learn', '你好', 'Hello');
            """, nil, nil, nil)
        sqlite3_close(db)
        for _ in 0..<2 {
            let store = try HistoryStore(url: url)
            #expect(store.recent().map(\.translation) == ["Hello"])
            #expect(store.recent().first?.passages == [])
        }
    }
}
