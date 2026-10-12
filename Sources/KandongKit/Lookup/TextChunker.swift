import Foundation

/// Splits text that is too long for a model into pieces, never mid-sentence unless a single
/// sentence is itself too long.
public enum TextChunker {
    private static let sentenceEnds: Set<Character> = ["。", "！", "？", "；", "…", "!", "?"]
    private static let clauseEnds: Set<Character> = ["，", "、", ",", ";", "：", ":"]
    private static let closers: Set<Character> = ["”", "’", "」", "』", "）", ")", "\"", "'", "】", "》"]

    /// Sentences, each keeping its punctuation and the whitespace after it, so joining them
    /// gives back the text.
    public static func sentences(_ text: String) -> [String] {
        split(text) { character, next in
            if character.isNewline { return true }
            // ASCII marks end a sentence only before whitespace, so 3.5 and URLs (…/?q=1) stay whole.
            if character.isASCII { return (sentenceEnds.contains(character) || character == ".") && endsToken(next) }
            return sentenceEnds.contains(character)
        }
    }

    /// Clauses of one sentence, split after commas and similar marks.
    public static func clauses(_ sentence: String) -> [String] {
        split(sentence) { character, next in
            clauseEnds.contains(character) && (!character.isASCII || endsToken(next))
        }
    }

    /// The text cut into two halves near the middle; the last resort for a clause that won't fit.
    /// Never cuts inside a run of non-Chinese characters (a URL, @mention or English word), which
    /// the model must keep exactly; text that is all one such run stays whole.
    public static func halves(_ text: String) -> [String] {
        let characters = Array(text)
        guard characters.count > 1 else { return [text] }
        func isWordPart(_ character: Character) -> Bool { character.isASCII && !character.isWhitespace }
        let cuts = (1..<characters.count).filter { !(isWordPart(characters[$0 - 1]) && isWordPart(characters[$0])) }
        guard let cut = cuts.min(by: { abs($0 - characters.count / 2) < abs($1 - characters.count / 2) }) else { return [text] }
        return [String(characters[..<cut]), String(characters[cut...])]
    }

    /// Smaller pieces of a unit that doesn't fit: its clauses if it has several, else its halves.
    public static func smaller(_ unit: String) -> [String] {
        let parts = clauses(unit)
        return parts.count > 1 ? parts : halves(unit)
    }

    private static func endsToken(_ next: Character?) -> Bool {
        next == nil || next!.isWhitespace || next!.isHan
    }

    private static func split(_ text: String, isBoundary: (Character, Character?) -> Bool) -> [String] {
        let characters = Array(text)
        var units: [String] = []
        var current = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            current.append(character)
            index += 1
            let next = index < characters.count ? characters[index] : nil
            guard isBoundary(character, next) else { continue }
            // Keep closing quotes and the following whitespace with the unit just ended.
            while index < characters.count, closers.contains(characters[index]) || characters[index].isWhitespace {
                current.append(characters[index])
                index += 1
            }
            units.append(current)
            current = ""
        }
        if !current.isEmpty { units.append(current) }
        return units
    }

    /// One piece of a longer text and the text just before it, for context.
    public struct Piece: Equatable, Sendable {
        public var text: String
        public var preceding: String?
    }

    /// Groups units into the largest consecutive pieces that `fits` accepts. A piece is measured
    /// with the last unit of the piece before it as context. A single unit that doesn't fit is
    /// broken into `smaller` units; nil means even one character doesn't fit.
    public static func pack(_ units: [String], fits: (_ piece: String, _ preceding: String?) async -> Bool) async -> [Piece]? {
        var remaining = units
        var pieces: [Piece] = []
        var preceding: String?
        while !remaining.isEmpty {
            if await fits(remaining.joined(), preceding) {
                pieces.append(Piece(text: remaining.joined(), preceding: preceding))
                break
            }
            guard await fits(remaining[0], preceding) else {
                let unit = remaining.removeFirst()
                guard unit.count > 1 else { return nil }
                remaining.insert(contentsOf: smaller(unit), at: 0)
                continue
            }
            // Binary search for the most units that fit: `low` fits, `high` doesn't.
            var low = 1, high = remaining.count
            while high - low > 1 {
                let middle = (low + high) / 2
                if await fits(remaining[..<middle].joined(), preceding) { low = middle } else { high = middle }
            }
            pieces.append(Piece(text: remaining[..<low].joined(), preceding: preceding))
            preceding = remaining[low - 1]
            remaining.removeFirst(low)
        }
        return pieces
    }
}
