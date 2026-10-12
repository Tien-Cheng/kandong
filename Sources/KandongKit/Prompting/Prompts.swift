import Foundation

/// What the Backend returns for a Learn Lookup.
public struct LearnReply: Codable, Hashable, Sendable {
    public struct ReadingCorrection: Codable, Hashable, Sendable {
        public var word: String
        public var pinyin: String
    }

    public var translation: String
    public var readingCorrections: [ReadingCorrection]

    public init(translation: String, readingCorrections: [ReadingCorrection] = []) {
        self.translation = translation
        self.readingCorrections = readingCorrections
    }

    // Local models sometimes drop the empty list; treat it as "no corrections".
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        translation = try c.decode(String.self, forKey: .translation)
        readingCorrections = (try? c.decodeIfPresent([ReadingCorrection].self, forKey: .readingCorrections)) ?? []
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
    note: one short sentence on register or a common alternative phrasing, or "" if nothing useful.
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

    private static func steering(context: String, terms: [Term]) -> String {
        var parts: [String] = []
        if !context.isEmpty { parts.append("About me:\n\(context)") }
        if !terms.isEmpty {
            let lines = terms.map { term in
                "- \(term.chinese) → \(term.english)" + (term.note.isEmpty ? "" : " (\(term.note))")
            }
            parts.append("My Terms (always translate these this way):\n" + lines.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// With `askForReadings` off, the reply has only the Translation. `preceding` is the text just
    /// before this part of a longer text, given for context only.
    public static func learn(
        text: String, analysis: OfflineAnalysis, context: String, terms: [Term], askForReadings: Bool = true, preceding: String? = nil
    ) -> AIRequest {
        var user = steering(context: context, terms: terms)
        if !user.isEmpty { user += "\n\n" }
        user += precedingNote(preceding) + "Text:\n\(text)"
        guard askForReadings else {
            return AIRequest(system: translateSystem, user: user, schema: translationSchema, expectedReplyLength: replyLength(text), streamField: "translation")
        }
        let readings = analysis.uniqueWords.map { "\($0.text) [\($0.pinyin)]" }.joined(separator: "\n")
        user += "\n\nDictionary pinyin:\n\(readings)"
        return AIRequest(system: learnSystem, user: user, schema: learnSchema, expectedReplyLength: replyLength(text), streamField: "translation")
    }

    public static func reverse(text: String, context: String, terms: [Term], preceding: String? = nil) -> AIRequest {
        var user = steering(context: context, terms: terms)
        if !user.isEmpty { user += "\n\n" }
        user += precedingNote(preceding) + "English:\n\(text)"
        return AIRequest(system: reverseSystem, user: user, schema: reverseSchema, expectedReplyLength: replyLength(text), streamField: "chinese")
    }

    public static func explain(text: String, translation: String?, context: String, terms: [Term]) -> AIRequest {
        var user = steering(context: context, terms: terms)
        if !user.isEmpty { user += "\n\n" }
        user += "Text:\n\(text)"
        if let translation, !translation.isEmpty { user += "\n\nTranslation (for reference):\n\(translation)" }
        // Explanations run several times longer than the text.
        return AIRequest(system: explainSystem, user: user, expectedReplyLength: 800 + text.count * 4)
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
}
