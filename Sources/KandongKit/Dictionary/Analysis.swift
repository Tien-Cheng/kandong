import Foundation

/// One piece of looked-up text: either a Chinese word or a Pass-through token.
public struct Segment: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case word
        /// Non-Chinese text (English, @mentions, identifiers, URLs, punctuation, whitespace) left untouched.
        case passThrough
    }

    public var id: Int
    public var kind: Kind
    /// Simplified form (identical to `original` for Simplified or non-Chinese text).
    public var text: String
    /// The text exactly as it appeared in the source (may be Traditional).
    public var original: String
    /// One syllable per character when `isAligned`, otherwise the whole word's reading.
    public var syllables: [Syllable]
    public var definitions: [String]
    public var hskLevel: Int?
    /// Other dictionary readings for the word, e.g. "liǎo" for 了.
    public var alternativeReadings: [String]
    /// True when the AI changed the dictionary reading for this context.
    public var readingCorrected: Bool
    /// What add-on dictionaries say the word means, e.g. a technical sense CC-CEDICT lacks.
    public var addOnGlosses: [AddOnGloss] = []

    public init(
        id: Int, kind: Kind, text: String, original: String, syllables: [Syllable] = [],
        definitions: [String] = [], hskLevel: Int? = nil, alternativeReadings: [String] = [],
        readingCorrected: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.original = original
        self.syllables = syllables
        self.definitions = definitions
        self.hskLevel = hskLevel
        self.alternativeReadings = alternativeReadings
        self.readingCorrected = readingCorrected
    }

    public var isWord: Bool { kind == .word }
    public var isAligned: Bool { syllables.count == text.count }
    public var pinyin: String { Pinyin.display(syllables) }
    public var isTraditional: Bool { original != text }
    /// CC-CEDICT's first senses, or an add-on's when CC-CEDICT doesn't know the word.
    public var gloss: String {
        definitions.isEmpty ? addOnGlosses.map(\.text).joined(separator: "; ") : definitions.prefix(3).joined(separator: "; ")
    }
}

/// An add-on dictionary's meaning for a word.
public struct AddOnGloss: Hashable, Codable, Sendable {
    /// The add-on's name.
    public var source: String
    public var text: String

    public init(source: String, text: String) {
        self.source = source
        self.text = text
    }
}

/// The instant, dictionary-only part of a Result.
public struct OfflineAnalysis: Hashable, Codable, Sendable {
    public var source: String
    public var segments: [Segment]

    public init(source: String, segments: [Segment]) {
        self.source = source
        self.segments = segments
    }

    public var words: [Segment] { segments.filter(\.isWord) }
    public var hasChinese: Bool { segments.contains(where: \.isWord) }
    public var containsTraditional: Bool { segments.contains(where: \.isTraditional) }
    public var simplifiedText: String { segments.map(\.text).joined() }

    /// Unique words in reading order, for the Word breakdown. A word read two ways (还 hái, 还 huán)
    /// appears once per reading.
    public var uniqueWords: [Segment] {
        var seen = Set<String>()
        return words.filter { seen.insert($0.text + " " + $0.pinyin.lowercased()).inserted }
    }
}

extension Character {
    /// CJK unified ideographs (incl. extensions A and B) and compatibility ideographs.
    public var isHan: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2A6DF, 0x3007: true
            default: false
            }
        }
    }
}

extension String {
    public var containsHan: Bool { contains(where: \.isHan) }
}
