import Foundation

/// One pinyin syllable with tone marks (e.g. "hǎo") and its tone number (1–4, 5 = neutral).
public struct Syllable: Hashable, Codable, Sendable {
    public var text: String
    public var tone: Int

    public init(text: String, tone: Int) {
        self.text = text
        self.tone = tone
    }

    /// Parses a tone-marked syllable such as "lǜ" or "de".
    public init(marked: String) {
        self.init(text: marked, tone: Pinyin.tone(ofMarked: marked))
    }
}

public enum Pinyin {
    private static let marks: [Character: [Character]] = [
        "a": ["ā", "á", "ǎ", "à"], "e": ["ē", "é", "ě", "è"], "i": ["ī", "í", "ǐ", "ì"],
        "o": ["ō", "ó", "ǒ", "ò"], "u": ["ū", "ú", "ǔ", "ù"], "ü": ["ǖ", "ǘ", "ǚ", "ǜ"],
        "A": ["Ā", "Á", "Ǎ", "À"], "E": ["Ē", "É", "Ě", "È"], "I": ["Ī", "Í", "Ǐ", "Ì"],
        "O": ["Ō", "Ó", "Ǒ", "Ò"], "U": ["Ū", "Ú", "Ǔ", "Ù"], "Ü": ["Ǖ", "Ǘ", "Ǚ", "Ǜ"],
    ]

    private static let toneOfMark: [Character: Int] = {
        var map: [Character: Int] = [:]
        for variants in marks.values {
            for (index, mark) in variants.enumerated() { map[mark] = index + 1 }
        }
        return map
    }()

    /// Converts CC-CEDICT numbered pinyin ("ni3 hao3", "lu:e4") into tone-marked syllables.
    public static func syllables(numbered: String) -> [Syllable] {
        numbered.split(separator: " ").map { syllable(numbered: String($0)) }
    }

    /// Converts one numbered syllable ("hao3") into a tone-marked syllable ("hǎo").
    public static func syllable(numbered raw: String) -> Syllable {
        var body = raw.replacingOccurrences(of: "u:", with: "ü")
            .replacingOccurrences(of: "U:", with: "Ü")
            .replacingOccurrences(of: "v", with: "ü")
        var tone = 5
        if let last = body.last, let digit = last.wholeNumberValue {
            tone = digit == 0 ? 5 : digit
            body.removeLast()
        } else if !body.contains(where: \.isLetter) {
            return Syllable(text: body, tone: 0)
        }
        guard (1...4).contains(tone), let index = markIndex(in: body) else {
            return Syllable(text: body, tone: tone)
        }
        var chars = Array(body)
        chars[index] = marks[chars[index]]![tone - 1]
        return Syllable(text: String(chars), tone: tone)
    }

    /// Standard placement: a/e take the mark; in "ou" the o does; otherwise the last vowel.
    private static func markIndex(in body: String) -> Int? {
        let chars = Array(body)
        let lower = chars.map { Character($0.lowercased()) }
        if let i = lower.firstIndex(where: { $0 == "a" || $0 == "e" }) { return i }
        if let i = lower.firstIndex(of: "o"), i + 1 < lower.count, lower[i + 1] == "u" { return i }
        return lower.lastIndex(where: { "aeiouü".contains($0) })
    }

    /// Tone of a tone-marked syllable; 5 when it has no mark.
    public static func tone(ofMarked text: String) -> Int {
        for char in text.precomposedStringWithCanonicalMapping {
            if let tone = toneOfMark[char] { return tone }
        }
        return text.contains(where: \.isLetter) ? 5 : 0
    }

    /// Letters only, lowercased, tone marks and ü-dots removed: "Lǜ shī" → "lushi".
    public static func folded(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .filter { $0.isLetter }
    }

    /// Joins syllables for display: "nǐ hǎo".
    public static func display(_ syllables: [Syllable]) -> String {
        syllables.map(\.text).joined(separator: " ")
    }
}
