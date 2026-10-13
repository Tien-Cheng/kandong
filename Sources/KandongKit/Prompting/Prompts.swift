import Foundation

/// What the Backend returns for a Learn Lookup.
public struct LearnReply: Codable, Hashable, Sendable {
    public struct ReadingCorrection: Codable, Hashable, Sendable {
        public var word: String
        public var pinyin: String
    }

    public var translation: String
    /// `ReadingMode.choose`: the reading chosen for each word that has more than one, by `ReadingChoice.key`.
    public var readings: [String: String]
    /// `ReadingMode.free`: words whose dictionary reading is wrong here, with the right one.
    public var readingCorrections: [ReadingCorrection]

    public init(translation: String, readings: [String: String] = [:], readingCorrections: [ReadingCorrection] = []) {
        self.translation = translation
        self.readings = readings
        self.readingCorrections = readingCorrections
    }

    // Local models sometimes drop the readings; treat it as "keep the dictionary's".
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        translation = try c.decode(String.self, forKey: .translation)
        readings = (try? c.decodeIfPresent([String: String].self, forKey: .readings)) ?? [:]
        readingCorrections = (try? c.decodeIfPresent([ReadingCorrection].self, forKey: .readingCorrections)) ?? []
    }
}

/// A word the dictionary can read more than one way (多音字), and the readings it allows: the
/// Backend picks one of these, so it can't make up pinyin.
public struct ReadingChoice: Hashable, Sendable {
    /// "w" and the word's Segment id, so each occurrence gets its own choice.
    public var key: String
    public var word: String
    /// The dictionary's reading first.
    public var options: [String]

    /// The words of `analysis` with more than one reading, at most `limit` of them.
    /// The limit only guards against huge schemas; a prompt too long for the Backend drops the
    /// readings altogether (`LookupEngine.fitted`).
    public static func all(in analysis: OfflineAnalysis, limit: Int = 200) -> [ReadingChoice] {
        analysis.segments.filter { $0.isWord && !$0.alternativeReadings.isEmpty }.prefix(limit).map {
            ReadingChoice(key: "w\($0.id)", word: $0.text, options: [$0.pinyin] + $0.alternativeReadings)
        }
    }
}

/// What the Backend returns for a Reverse Lookup.
public struct ReverseReply: Codable, Hashable, Sendable {
    public var chinese: String
    /// Register or usage remarks, possibly empty.
    public var note: String

    public init(chinese: String, note: String = "") {
        self.chinese = chinese
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chinese = try c.decode(String.self, forKey: .chinese)
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? ""
    }
}

/// Builds the prompts sent to Backends and reads their replies.
public enum Prompts {
    /// `ReadingMode.free`: the Translation, then any readings the model says are wrong.
    public static let learnSchema: JSONValue = [
        "type": "object",
        "additionalProperties": false,
        "required": ["translation", "readingCorrections"],
        "properties": [
            "translation": ["type": "string"],
            "readingCorrections": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["word", "pinyin"],
                    "properties": ["word": ["type": "string"], "pinyin": ["type": "string"]],
                ],
            ],
        ],
    ]

    /// `ReadingMode.choose`: the Translation, then one reading for each choice, from its options only.
    public static func choiceSchema(_ choices: [ReadingChoice]) -> JSONValue {
        var readings: [String: JSONValue] = [:]
        for choice in choices {
            readings[choice.key] = ["type": "string", "enum": .array(choice.options.map { .string($0) })]
        }
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["translation", "readings"],
            "properties": [
                "translation": ["type": "string"],
                "readings": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": .array(choices.map { .string($0.key) }),
                    "properties": .object(readings),
                ],
            ],
        ]
    }

    /// Learn without reading corrections, for Backends that don't make them.
    public static let translationSchema: JSONValue = [
        "type": "object",
        "additionalProperties": false,
        "required": ["translation"],
        "properties": ["translation": ["type": "string"]],
    ]

    public static let reverseSchema: JSONValue = [
        "type": "object",
        "additionalProperties": false,
        "required": ["chinese", "note"],
        "properties": ["chinese": ["type": "string"], "note": ["type": "string"]],
    ]

    static let learnSystem = learnInstructions + """
    Reply with one JSON object and nothing else:
    {"translation": string, "readingCorrections": [{"word": string, "pinyin": string}]}

    readingCorrections: the user gives dictionary pinyin for each word. List only words whose \
    pinyin is WRONG in this context (多音字 such as 了, 行, 得, 长, 重, 还, 着, 地). Give the correct \
    pinyin with tone marks, one space between syllables, citation tones (no tone sandhi). \
    Usually this list is empty.
    """

    static let chooseSystem = learnInstructions + """
    Reply with one JSON object and nothing else:
    {"translation": string, "readings": {"w1": string, ...}}

    readings: the user lists the words that can be read more than one way (多音字 such as 还, 行, 得, \
    了, 着, 长, 觉), each with its id and the readings the dictionary allows, the dictionary's guess \
    first. For every id, give the reading the word has in this text, copied exactly from its list. \
    Keep the first unless the context calls for another (还没 hái, 还给 huán; 睡着 zháo, 挂着 zhe; \
    得走 děi, 得到 dé, 跑得快 de).
    """

    static let translateSystem = learnInstructions + """
    Reply with one JSON object and nothing else: {"translation": string}
    """

    private static let learnInstructions = """
    You help an English-speaking learner read Chinese text they came across.

    translation: natural, idiomatic English as a native speaker would say it. You MUST write it in English. Keep \
    every non-Chinese fragment exactly as written (English words, @mentions, hashtags, URLs, numbers). \
    Use the user's Terms exactly when their Chinese appears. Match the tone (casual chat stays casual).

    """

    static let reverseSystem = """
    You help an English-speaking learner say things in Chinese. Translate the user's English into \
    natural Simplified Chinese as a native speaker would write it, matching the user's tone. \
    Keep @mentions, hashtags and URLs unchanged. Use the user's Terms exactly. \
    Reply with one JSON object and nothing else: {"chinese": string, "note": string}. \
    note: one short sentence in English on how formal or casual it sounds, or a common alternative \
    phrasing; "" if nothing useful. You MUST write the note in English.
    """

    static let explainSystem = """
    You are a patient Chinese teacher for an English-speaking adult learner. Explain the Chinese \
    text the user gives, in English, using Markdown. Be concise and concrete; skip anything obvious. \
    Cover, as relevant:
    - **Structure**: how the sentence is built, chunk by chunk.
    - **Grammar**: particles and patterns (了/过/着, 把/被, 是…的, complements, measure words) — what they do here.
    - **Words**: notable words or idioms, with pinyin, nuance and a short example.
    - **Register**: how formal or casual it is, and anything a native would read between the lines.
    Write pinyin with tone marks. Keep non-Chinese fragments as they are; don't explain them. \
    You MUST respond in English.
    """

    static let transcribeSystem = """
    Transcribe all text in the image exactly as written, preserving line breaks and reading order. \
    Do not translate, explain or add anything. If there is no text, reply with nothing.
    """

    /// Room for a reply to `text`: an English translation of Chinese runs about 0.9 tokens a character, plus the JSON.
    static func replyLength(_ text: String) -> Int {
        text.count * 6 / 5 + 200
    }

    private static func precedingNote(_ preceding: String?) -> String {
        guard let preceding = preceding?.trimmingCharacters(in: .whitespacesAndNewlines), !preceding.isEmpty else { return "" }
        return "Preceding text (for context only; don't translate it):\n\(preceding.suffix(200))\n\n"
    }

    /// Context cut to about `limit` characters at a line break, for prompts that are short of room.
    public static func trimmed(context: String, limit: Int) -> String {
        guard context.count > limit else { return context }
        let head = context.prefix(limit)
        let cut = head.lastIndex(of: "\n").map { head[..<$0] } ?? head
        return String(cut).trimmingCharacters(in: .whitespacesAndNewlines) + " …"
    }

    private static func steering(context: String, terms: [Term], glossary: [Segment] = []) -> String {
        var parts: [String] = []
        if !context.isEmpty { parts.append("About me:\n\(context)") }
        if !terms.isEmpty {
            let lines = terms.map { term in
                "- \(term.chinese) → \(term.english)" + (term.note.isEmpty ? "" : " (\(term.note))")
            }
            parts.append("My Terms (always translate these this way):\n" + lines.joined(separator: "\n"))
        }
        // Terms win; they may be written in Traditional characters.
        let known = Set(terms.flatMap { [$0.chinese, $0.chinese.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? $0.chinese] })
        let entries = glossary.filter { !$0.addOnGlosses.isEmpty && !known.contains($0.text) && !known.contains($0.original) }.prefix(20)
        if !entries.isEmpty {
            let lines = entries.map { "- \($0.text) → " + $0.addOnGlosses.prefix(3).map(\.text).joined(separator: "; ") }
            parts.append("Glossary (specialist meanings; use them where they fit):\n" + lines.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// `readings` sets how the reply may change dictionary readings; with `.off` it has only the
    /// Translation. `preceding` is the text just before this part of a longer text, for context only.
    public static func learn(
        text: String, analysis: OfflineAnalysis, context: String, terms: [Term], readings: ReadingMode = .free, preceding: String? = nil
    ) -> AIRequest {
        var user = steering(context: context, terms: terms, glossary: analysis.uniqueWords.filter { text.contains($0.original) || text.contains($0.text) })
        if !user.isEmpty { user += "\n\n" }
        user += precedingNote(preceding) + "Text:\n\(text)"
        switch readings {
        case .off:
            return AIRequest(system: translateSystem, user: user, schema: translationSchema, expectedReplyLength: replyLength(text), streamField: "translation")
        case .free:
            let list = analysis.uniqueWords.map { "\($0.text) [\($0.pinyin)]" }.joined(separator: "\n")
            user += "\n\nDictionary pinyin:\n\(list)"
            return AIRequest(system: learnSystem, user: user, schema: learnSchema, expectedReplyLength: replyLength(text), streamField: "translation")
        case .choose:
            break
        }
        // Choices are asked only with the whole text: the ids are the whole text's words, and a part
        // can't be asked about occurrences it doesn't contain.
        let choices = text == analysis.source ? ReadingChoice.all(in: analysis) : []
        guard !choices.isEmpty else {
            return AIRequest(system: translateSystem, user: user, schema: translationSchema, expectedReplyLength: replyLength(text), streamField: "translation")
        }
        let list = choices.map { "\($0.key) \($0.word): \($0.options.joined(separator: " | "))" }.joined(separator: "\n")
        user += "\n\nWords with more than one reading:\n\(list)"
        return AIRequest(
            system: chooseSystem, user: user, schema: choiceSchema(choices),
            expectedReplyLength: replyLength(text) + choices.count * 12, streamField: "translation"
        )
    }

    public static func reverse(text: String, context: String, terms: [Term], preceding: String? = nil) -> AIRequest {
        var user = steering(context: context, terms: terms)
        if !user.isEmpty { user += "\n\n" }
        user += precedingNote(preceding) + "English:\n\(text)"
        return AIRequest(system: reverseSystem, user: user, schema: reverseSchema, expectedReplyLength: replyLength(text), streamField: "chinese")
    }

    public static func explain(text: String, translation: String?, context: String, terms: [Term], glossary: [Segment] = []) -> AIRequest {
        var user = steering(context: context, terms: terms, glossary: glossary)
        if !user.isEmpty { user += "\n\n" }
        user += "Text:\n\(text)"
        if let translation, !translation.isEmpty { user += "\n\nTranslation (for reference):\n\(translation)" }
        // Explanations run several times longer than the text.
        return AIRequest(system: explainSystem, user: user, expectedReplyLength: 800 + text.count * 4, task: .explain)
    }

    public static func transcribe(image: Data) -> AIRequest {
        AIRequest(system: transcribeSystem, user: "Transcribe the text in this image.", image: image)
    }

    // MARK: Replies

    public static func parseLearn(_ reply: String) throws -> LearnReply {
        try decode(LearnReply.self, from: reply)
    }

    public static func parseReverse(_ reply: String) throws -> ReverseReply {
        try decode(ReverseReply.self, from: reply)
    }

    /// Apple's model sometimes carries on after its answer by repeating the reply format its framework
    /// added to the prompt ("响应使用以下JSON格式：{"type": …"). From such a line on, the reply is
    /// dropped, unless the English being translated mentions JSON or has braces of its own.
    public static func withoutFormatEcho(_ text: String, source: String) -> String {
        guard !source.localizedCaseInsensitiveContains("json"), !source.contains("{") else { return text }
        let lines = text.components(separatedBy: "\n")
        guard let echo = lines.indices.dropFirst().first(where: { index in
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            return line.contains("响应使用以下JSON格式") || line.hasPrefix(#"{"type":"#) || line.hasPrefix(#"{"type" :"#)
        }) else { return text }
        return lines[..<echo].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decode<T: Decodable>(_ type: T.Type, from reply: String) throws -> T {
        let text = visibleText(reply)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw BackendError.badResponse("no JSON object in reply: \(text.prefix(200))")
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(text[start...end].utf8))
        } catch {
            throw BackendError.badResponse("\(error.localizedDescription) — \(text.prefix(200))")
        }
    }

    /// Removes `<think>…</think>` reasoning that some local models emit, including an unfinished one.
    public static func visibleText(_ reply: String) -> String {
        var text = reply
        while let open = text.range(of: "<think>") {
            if let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                text.removeSubrange(open.lowerBound..<text.endIndex)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An Explanation without the ```markdown fence models sometimes wrap it in, which would show it
    /// as code. Only a fence opening the Explanation, or one of its parts, is a wrapper; code blocks
    /// within it stay. The closing fence may not have arrived yet while the reply streams in.
    public static func unfenced(_ text: String) -> String {
        var lines: [Substring] = []
        var wrapped = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            let previous = lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.trimmingCharacters(in: .whitespaces)
            let opensPart = previous == nil || previous == "---" || previous?.hasPrefix("**Part ") == true
            if !wrapped, opensPart, ["```", "```markdown", "```md"].contains(trimmed) {
                wrapped = true
            } else if wrapped, trimmed == "```" {
                wrapped = false
            } else {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
