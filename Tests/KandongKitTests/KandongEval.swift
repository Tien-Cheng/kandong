import Foundation
import Testing
@testable import KandongKit

private let evalBackendName = ProcessInfo.processInfo.environment["KANDONG_EVAL_BACKEND"] ?? "apple"
private let evalEnabled = ProcessInfo.processInfo.environment["KANDONG_LIVE"] == "1" && TestData.hasDictionary
    && (evalBackendName != "apple" || AppleIntelligenceBackend.unavailability == nil)

/// Kandong's dev eval: runs real Lookups (Learn, Reverse, Explain) through `LookupEngine` against one Backend,
/// scores them and prints a report. Quality never fails the test; only a Backend that answers nothing does.
///
///     KANDONG_LIVE=1 KANDONG_EVAL_BACKEND=lmstudio:google/gemma-4-e4b swift test --filter KandongEval
///
/// `KANDONG_EVAL_BACKEND` is `apple` (the default), `codex`, or `lmstudio:<model id>` (LM Studio at localhost:1234);
/// `KANDONG_EVAL_READINGS` is `free` (the default) or `choose`, the `ReadingMode` used for 多音字;
/// `KANDONG_EVAL_TIMEOUT` caps each call (seconds, default 90). A timed-out Codex call isn't interrupted (the Codex
/// Backend doesn't stop a running turn), so it may keep running while the next case starts.
///
/// Apple Intelligence on macOS 27.0.1 (AFM 3 Core Advanced) fixed 1 多音字, missed 2–3 and turned 1–3 readings
/// wrong (e.g. 还给 huán → hái) over two runs, which is why it doesn't correct readings by default.
@Suite(.enabled(if: evalEnabled), .serialized)
struct KandongEval {
    static let backendName = evalBackendName
    /// Seconds before a call counts as failed; thinking models can reason for minutes.
    static let timeout = Double(ProcessInfo.processInfo.environment["KANDONG_EVAL_TIMEOUT"] ?? "").flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 90

    static func backend(named name: String) -> AIBackend? {
        switch name {
        case "apple": return AppleIntelligenceBackend()
        case "codex": return CodexBackend(settings: CodexSettings())
        case _ where name.hasPrefix("lmstudio:"):
            var config = BackendConfig.openAI(.lmStudio, id: "lmstudio")
            config.openAI?.model = String(name.dropFirst("lmstudio:".count))
            return OpenAICompatibleBackend(config: config)
        default: return nil
        }
    }

    // MARK: Cases

    /// 多音字: the bracketed character must read as given in context. The first 12 the dictionary gets
    /// wrong (一行 can't be fixed by choosing: CC-CEDICT only reads it yī xíng); the rest it gets right,
    /// so a Backend can only make them worse.
    static let polyphones: [(String, String)] = [
        ("我[还]没吃饭。", "hái"), ("你[还]好吗？", "hái"), ("这样[行]不行？", "xíng"), ("这一[行]字写错了。", "háng"),
        ("你[得]早点儿来。", "děi"), ("我昨天睡了一[觉]。", "jiào"), ("吃完[了]吗？", "le"), ("他睡[着]了。", "zháo"),
        ("你猜[着]了吗？", "zháo"), ("这个[长]得很高。", "zhǎng"), ("[数]一数有几个。", "shǔ"), ("他[背]着书包。", "bēi"),
        ("请把书[还]给我。", "huán"), ("他借钱不[还]。", "huán"), ("你真[行]！", "xíng"), ("我[得]走了。", "děi"),
        ("他[得]了第一名。", "dé"), ("说[得]对。", "de"), ("这事[得]好好想想。", "děi"), ("我明白[了]。", "le"),
        ("墙上挂[着]画。", "zhe"), ("这条路很[长]。", "cháng"), ("这个箱子很[重]。", "zhòng"), ("这个菜很[便]宜。", "pián"),
        ("我[为]你高兴。", "wèi"), ("我的成绩很[差]。", "chà"), ("他慢慢[地]走了。", "de"), ("这个字怎么[读]？", "dú"),
        ("你[都]来了。", "dōu"), ("他[会]来的。", "huì"), ("我[只]有一个。", "zhǐ"), ("一[只]猫。", "zhī"),
        ("天气很[好]。", "hǎo"), ("我们[种]了很多树。", "zhòng"), ("他[和]我一起去。", "hé"), ("这是[假]的。", "jiǎ"),
        ("他[哄]孩子睡觉。", "hǒng"), ("这题很[难]。", "nán"), ("把门[背]上。", "bēi"),
    ]

    struct Check {
        var text: String
        /// Must appear exactly (case-sensitive), not as part of a longer token: `#CET60` doesn't keep `#CET6`.
        var keep: [String] = []
        /// Each group needs one of its options (case-insensitive).
        var anyOf: [[String]] = []
    }

    static let terms = [Term(chinese: "小红书", english: "RedNote"), Term(chinese: "微信", english: "WeChat")]

    /// Learn: pass-through tokens, Terms (also the Workspace's starter 加油 → "you've got this") and tone.
    static let learnChecks = [
        Check(text: "明天考试，@Xiao Ming 加油！今晚再看一遍Quizlet", keep: ["@Xiao Ming", "Quizlet"], anyOf: [["got this"]]),
        Check(text: "@Lily 你看这个 https://xhslink.com/a/Ab3dE 小红书上很火", keep: ["@Lily", "https://xhslink.com/a/Ab3dE", "RedNote"]),
        Check(text: "我把照片发到微信群了，你看一下", keep: ["WeChat"]),
        Check(text: "#CET6 还剩30天了，每天背50个单词", keep: ["#CET6", "30", "50"]),
        Check(text: "这件外套打完折才299块，原价899", keep: ["299", "899"]),
        Check(text: "我用iPhone 17 Pro拍的，发到Instagram上了", keep: ["iPhone 17 Pro", "Instagram"]),
        Check(text: "这个bug我明天再fix，先push到main", keep: ["bug", "main"]),
        Check(text: "哈哈哈笑死我了，你也太搞笑了吧", anyOf: [["haha", "lol", "lmao", "dying", "dead", "😂"]]),
        Check(text: "在吗？晚上一起吃火锅不", anyOf: [["hotpot", "hot pot"]]),
    ]

    /// Reverse: Chinese, Simplified, pass-through tokens and Terms kept.
    static let reverseChecks = [
        Check(text: "@Lily want to grab hotpot tonight?", keep: ["@Lily"]),
        Check(text: "Shall we practise speaking together this weekend?"),
        Check(text: "I'll send you the link on WeChat later, check #HSK4", keep: ["#HSK4", "微信"]),
        // Apple Intelligence once answered 注册或使用本地环境进行开发 ("register…"), echoing the prompt.
        Check(text: "Build local multimodal agents with the first encoder-free architecture", keep: ["多模态"]),
    ]

    /// Explain: English Markdown that covers the key grammar point.
    static let explainChecks = [
        Check(text: "你跟老师沟通过了吗？", keep: ["过"]),
        Check(text: "他把作业写完了。", keep: ["把"]),
    ]

    // MARK: Run

    @Test func eval() async throws {
        guard let backend = Self.backend(named: Self.backendName) else {
            Issue.record("Unknown KANDONG_EVAL_BACKEND \(Self.backendName): use apple, codex or lmstudio:<model id>")
            return
        }
        let workspace = Workspace(folder: FileManager.default.temporaryDirectory.appendingPathComponent("kandong-eval-\(UUID().uuidString)"))
        try workspace.ensureExists()
        for term in Self.terms { try workspace.upsertTerm(term) }
        let run = Run(engine: LookupEngine(analyzer: TestData.analyzer!, workspace: workspace), backend: backend)
        await run.polyphones()
        await run.learn()
        await run.reverse()
        await run.explain()
        print(run.report)
        if run.calls.allSatisfy({ $0.error != nil }) { Issue.record("Every call failed: \(run.calls.first?.error ?? "")") }
    }

    struct Call {
        var kind: String
        var seconds: Double
        var error: String?
        var structured: Bool { kind != "explain" }
        var badJSON: Bool { error?.hasPrefix("bad JSON") ?? false }
    }

    final class Run: @unchecked Sendable {
        let engine: LookupEngine
        let backend: AIBackend
        var calls: [Call] = []
        var kept = 0, unanswered = 0, fixed: [String] = [], missed: [String] = [], invented: [String] = [], elsewhere: [String] = []
        var failures: [String: [String]] = [:]
        var passed: [String: Int] = [:]
        var samples: [String] = []

        init(engine: LookupEngine, backend: AIBackend) {
            self.engine = engine
            self.backend = backend
        }

        /// Times one Backend call; a thrown error is recorded and returned as nil.
        func call<T: Sendable>(_ kind: String, _ body: @escaping @Sendable () async throws -> T) async -> T? {
            let start = ContinuousClock.now
            var error: String?
            var value: T?
            do { value = try await KandongEval.withTimeout(body) } catch let BackendError.badResponse(message) {
                error = "bad JSON: \(message)"
            } catch let other {
                error = other.localizedDescription
            }
            let elapsed = ContinuousClock.now - start
            calls.append(Call(kind: kind, seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18, error: error))
            return value
        }

        func score(_ section: String, _ text: String, _ problems: [String]) {
            if problems.isEmpty { passed[section, default: 0] += 1 } else {
                failures[section, default: []].append("\(text) — \(problems.joined(separator: "; "))")
            }
        }

        func polyphones() async {
            let engine = engine, backend = backend
            let correcting = CorrectingReadings(base: backend)
            for (marked, expected) in KandongEval.polyphones {
                let offset = marked.distance(from: marked.startIndex, to: marked.firstIndex(of: "[")!)
                let sentence = marked.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                let before = engine.offline(sentence)
                guard let after = await call("learn", { try await engine.learn(before, backend: correcting).analysis }) else {
                    unanswered += 1
                    continue
                }
                let dictionary = KandongEval.reading(at: offset, in: before) ?? "?"
                let final = KandongEval.reading(at: offset, in: after) ?? "?"
                let label = "\(sentence) \(dictionary)→\(final) (want \(expected))"
                switch (KandongEval.same(dictionary, expected), KandongEval.same(final, expected)) {
                case (true, true): kept += 1
                case (false, true): fixed.append(label)
                case (false, false) where KandongEval.same(dictionary, final): missed.append(label)
                default: invented.append(label)
                }
                for segment in after.segments where segment.readingCorrected && !segment.text.contains(Array(sentence)[offset]) {
                    elsewhere.append("\(sentence): \(segment.text) → \(segment.pinyin)")
                }
            }
        }

        func learn() async {
            let engine = engine, backend = backend
            for check in KandongEval.learnChecks {
                guard let (translation, _) = await call("learn", { try await engine.learn(engine.offline(check.text), backend: backend) }) else {
                    score("learn", check.text, ["error: \(calls.last?.error ?? "")"])
                    continue
                }
                samples.append("\(check.text)\n    → \(translation)")
                var problems = KandongEval.missing(check, in: translation)
                if KandongEval.isUntranslated(translation) { problems.append("untranslated: \(translation)") }
                else if !problems.isEmpty { problems.append("got: \(translation)") }
                score("learn", check.text, problems)
            }
        }

        func reverse() async {
            let engine = engine, backend = backend
            for check in KandongEval.reverseChecks {
                guard let (reply, analysis) = await call("reverse", { try await engine.reverse(check.text, backend: backend) }) else {
                    score("reverse", check.text, ["error: \(calls.last?.error ?? "")"])
                    continue
                }
                samples.append("\(check.text)\n    → \(reply.chinese)" + (reply.note.isEmpty ? "" : "  (\(reply.note))"))
                var problems = KandongEval.missing(check, in: reply.chinese)
                if !reply.chinese.containsHan { problems.append("no Chinese") }
                if analysis.containsTraditional { problems.append("Traditional") }
                if KandongEval.isUntranslated(reply.note) { problems.append("note not in English") }
                if reply.chinese.contains("JSON") || reply.chinese.contains("{") { problems.append("format text in the reply") }
                if !problems.isEmpty { problems.append("got: \(reply.chinese)") }
                score("reverse", check.text, problems)
            }
        }

        func explain() async {
            let engine = engine, backend = backend
            for check in KandongEval.explainChecks {
                guard let text = await call("explain", {
                    var text = ""
                    for try await delta in engine.explain(check.text, translation: nil, backend: backend) { text += delta }
                    text = Prompts.visibleText(text)
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw BackendError.failed("empty reply") }
                    return text
                }) else {
                    score("explain", check.text, ["error: \(calls.last?.error ?? "")"])
                    continue
                }
                var problems = KandongEval.missing(check, in: text)
                if KandongEval.isUntranslated(text) { problems.append("not in English") }
                if !["**", "- ", "#"].contains(where: text.contains) { problems.append("no Markdown") }
                score("explain", check.text, problems)
            }
        }

        var report: String {
            let structured = calls.filter(\.structured)
            let seconds = calls.map(\.seconds).sorted()
            func rate(_ section: String, _ total: Int) -> String { "\(passed[section] ?? 0)/\(total)" }
            var lines = [
                "Kandong eval — \(backend.label) (readings: \(CorrectingReadings(base: backend).readingMode.rawValue) here, \(backend.readingMode.rawValue) in the app)",
                "| 多音字 | kept \(kept), fixed \(fixed.count), missed \(missed.count), invented wrong \(invented.count), errors \(unanswered) (of \(KandongEval.polyphones.count)) |",
                "| Learn fidelity | \(rate("learn", KandongEval.learnChecks.count)) |",
                "| Reverse | \(rate("reverse", KandongEval.reverseChecks.count)) |",
                "| Explain | \(rate("explain", KandongEval.explainChecks.count)) |",
                "| Learn/Reverse Lookups that finished | \(structured.count(where: { $0.error == nil }))/\(structured.count) (failed on bad JSON \(structured.count(where: \.badJSON))) |",
                "| Latency | median \(KandongEval.format(KandongEval.percentile(seconds, 0.5))), p90 \(KandongEval.format(KandongEval.percentile(seconds, 0.9))), total \(KandongEval.format(seconds.reduce(0, +))) over \(calls.count) calls |",
            ]
            for kind in ["learn", "reverse", "explain"] {
                let times = calls.filter { $0.kind == kind }.map(\.seconds).sorted()
                lines.append("|   \(kind) | median \(KandongEval.format(KandongEval.percentile(times, 0.5))), p90 \(KandongEval.format(KandongEval.percentile(times, 0.9))) |")
            }
            lines.append("\n多音字 fixed: \(fixed)\n  missed: \(missed)\n  invented: \(invented)\n  corrections elsewhere (review by hand): \(elsewhere)")
            for section in ["learn", "reverse", "explain"] {
                for failure in failures[section] ?? [] { lines.append("FAIL \(section): \(failure)") }
            }
            for call in calls where call.error != nil && call.kind == "learn" && !call.badJSON { lines.append("ERROR: \(call.error!)") }
            lines.append("\nTranslations:")
            lines += samples.map { "  " + $0 }
            return lines.joined(separator: "\n")
        }
    }

    struct TimedOut: LocalizedError {
        var errorDescription: String? { "timed out after \(KandongEval.format(KandongEval.timeout))" }
    }

    static func withTimeout<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw TimedOut()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // MARK: Scoring

    static func missing(_ check: Check, in text: String) -> [String] {
        check.keep.filter { !containsToken($0, in: text) }.map { "missing \($0)" }
            + check.anyOf.filter { group in !group.contains { text.localizedCaseInsensitiveContains($0) } }.map { "none of \($0)" }
    }

    /// Whether `token` appears without ASCII letters or digits running on from either end, so a changed
    /// `@Lily2`, `#CET60`, `2999` or a longer URL doesn't count as keeping `@Lily`, `#CET6`, `299` or the URL.
    static func containsToken(_ token: String, in text: String) -> Bool {
        let runsOn: (Character?) -> Bool = { $0.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false }
        var searchStart = text.startIndex
        while let range = text.range(of: token, range: searchStart..<text.endIndex) {
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            let startsWithWord = token.first.map(runsOn) ?? false, endsWithWord = token.last.map(runsOn) ?? false
            if !(startsWithWord && runsOn(before)) && !(endsWithWord && runsOn(after)) { return true }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }

    /// More than a third of the letters are Han: the model answered in Chinese.
    static func isUntranslated(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter)
        return !letters.isEmpty && letters.filter(\.isHan).count * 3 > letters.count
    }

    /// The pinyin of the character at `offset` in the analysed text.
    static func reading(at offset: Int, in analysis: OfflineAnalysis) -> String? {
        var position = 0
        for segment in analysis.segments {
            let length = segment.text.count
            if offset < position + length {
                let index = offset - position
                return segment.syllables.count == length ? Pinyin.display([segment.syllables[index]]) : nil
            }
            position += length
        }
        return nil
    }

    static func same(_ a: String, _ b: String) -> Bool {
        a.lowercased().trimmingCharacters(in: .whitespaces) == b.lowercased()
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        sorted.isEmpty ? 0 : sorted[max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1)]
    }

    static func format(_ seconds: Double) -> String { String(format: "%.1fs", seconds) }
}

/// Asks the Backend for readings in `KANDONG_EVAL_READINGS` mode (`free` unless set to `choose`),
/// whatever the app would.
private struct CorrectingReadings: AIBackend {
    let base: AIBackend
    var label: String { base.label }
    var readingMode: ReadingMode { ReadingMode(rawValue: ProcessInfo.processInfo.environment["KANDONG_EVAL_READINGS"] ?? "") ?? .free }
    func supportsImages() async -> Bool { await base.supportsImages() }
    func respond(to request: AIRequest) -> AsyncThrowingStream<String, Error> { base.respond(to: request) }
}

/// The eval's scoring, checked offline.
struct KandongEvalScoringTests {
    @Test func keptTokensMustNotRunOn() {
        #expect(KandongEval.containsToken("#CET6", in: "#CET6: 30 days left."))
        #expect(!KandongEval.containsToken("#CET6", in: "#CET60: 300 days left."))
        #expect(!KandongEval.containsToken("30", in: "300 days"))
        #expect(KandongEval.containsToken("30", in: "300 days, 30 left"))
        #expect(!KandongEval.containsToken("@Lily", in: "@Lily2 look"))
        #expect(KandongEval.containsToken("@Lily", in: "Hey @Lily, look"))
        #expect(!KandongEval.containsToken("https://xhslink.com/a/Ab3dE", in: "https://xhslink.com/a/Ab3dEvil"))
        #expect(KandongEval.containsToken("https://xhslink.com/a/Ab3dE", in: "(https://xhslink.com/a/Ab3dE)."))
        #expect(KandongEval.containsToken("微信", in: "发到微信群"))
        #expect(!KandongEval.containsToken("299", in: "2999 yuan"))
    }
}
