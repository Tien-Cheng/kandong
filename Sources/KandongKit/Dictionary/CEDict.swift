import Foundation

/// One CC-CEDICT line: `傳統 传统 [chuan2 tong3] /tradition/traditional/`.
public struct DictEntry: Hashable, Sendable {
    public let traditional: String
    public let simplified: String
    /// Numbered pinyin as written in CC-CEDICT, e.g. "chuan2 tong3".
    public let numberedPinyin: String
    public let definitions: [String]

    public var syllables: [Syllable] { Pinyin.syllables(numbered: numberedPinyin) }
    public var foldedPinyin: String { Pinyin.folded(Pinyin.display(syllables)) }

    /// True for proper nouns (CC-CEDICT capitalises their pinyin).
    public var isProperNoun: Bool { numberedPinyin.first?.isUppercase ?? false }
}

/// The offline CC-CEDICT dictionary, indexed by both simplified and traditional forms.
public final class CEDict: Sendable {
    private let entries: [DictEntry]
    private let index: [String: [Int]]
    public let maxWordLength: Int

    public convenience init(contentsOf url: URL) throws {
        try self.init(text: String(contentsOf: url, encoding: .utf8))
    }

    public init(text: String) {
        var entries: [DictEntry] = []
        entries.reserveCapacity(130_000)
        var index: [String: [Int]] = [:]
        index.reserveCapacity(260_000)
        var maxLength = 1
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.first != "#", let entry = Self.parse(line) else { continue }
            let id = entries.count
            entries.append(entry)
            index[entry.simplified, default: []].append(id)
            if entry.traditional != entry.simplified {
                index[entry.traditional, default: []].append(id)
            }
            maxLength = max(maxLength, entry.simplified.count)
        }
        self.entries = entries
        self.index = index
        self.maxWordLength = min(maxLength, 12)
    }

    static func parse(_ line: Substring) -> DictEntry? {
        guard let firstSpace = line.firstIndex(of: " "),
              let open = line.firstIndex(of: "["),
              let close = line[open...].firstIndex(of: "]"),
              let slash = line[close...].firstIndex(of: "/")
        else { return nil }
        let traditional = line[..<firstSpace]
        let simplified = line[line.index(after: firstSpace)..<open].trimmingCharacters(in: .whitespaces)
        let pinyin = line[line.index(after: open)..<close]
        let definitions = line[slash...].split(separator: "/").map(String.init).filter { !$0.isEmpty }
        return DictEntry(
            traditional: String(traditional),
            simplified: simplified,
            numberedPinyin: String(pinyin),
            definitions: definitions
        )
    }

    public var count: Int { entries.count }

    /// All entries whose simplified or traditional form is `word`.
    public func entries(for word: String) -> [DictEntry] {
        index[word]?.map { entries[$0] } ?? []
    }

    public func contains(_ word: String) -> Bool { index[word] != nil }

    /// The entry most likely meant for `word`. `reading` (any tone-marked or plain pinyin, e.g. from
    /// the system tokenizer) narrows the choice to entries pronounced that way.
    public func bestEntry(for word: String, reading: [Syllable]? = nil) -> DictEntry? {
        let candidates = entries(for: word)
        guard !candidates.isEmpty else { return nil }
        if let reading, !reading.isEmpty {
            let folded = Pinyin.folded(Pinyin.display(reading))
            let sameLetters = candidates.filter { $0.foldedPinyin == folded }
            if !sameLetters.isEmpty {
                let tones = reading.map(\.tone)
                return sameLetters.max { lhs, rhs in
                    let l = toneAgreement(lhs, tones), r = toneAgreement(rhs, tones)
                    return l != r ? l < r : Self.usefulness(lhs) < Self.usefulness(rhs)
                }
            }
        }
        return candidates.max { Self.usefulness($0) < Self.usefulness($1) }
    }

    private func toneAgreement(_ entry: DictEntry, _ tones: [Int]) -> Int {
        zip(entry.syllables.map(\.tone), tones).filter { $0 == $1 }.count
    }

    /// Prefers common-word entries over surnames, proper nouns and "variant of" cross-references.
    static func usefulness(_ entry: DictEntry) -> Int {
        var score = 0
        for definition in entry.definitions {
            let lower = definition.lowercased()
            if lower.hasPrefix("variant of") || lower.hasPrefix("old variant of")
                || lower.hasPrefix("surname") || lower.hasPrefix("see ") || lower.hasPrefix("used in")
                || lower.hasPrefix("japanese variant") || lower.hasPrefix("archaic variant") {
                score -= 1
            } else {
                score += 3
            }
        }
        if entry.isProperNoun { score -= 10 }
        return score
    }
}
