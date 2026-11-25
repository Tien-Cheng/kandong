import Foundation

/// How a run of the Reading is set.
public enum ReadingFace: Hashable, Sendable {
    /// Chinese characters and full-width punctuation, in the user's Chinese typeface.
    case han
    /// Everything else: English, numbers, URLs, emoji.
    case latin
    case pinyin
}

/// The smallest piece of the Reading that is placed on its own.
public struct ReadingUnit: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case word(Segment)
        case text(String, ReadingFace)
        case lineBreak
    }

    public var kind: Kind
    /// No gap before it: punctuation, the name after "@", anything beside a full-width mark (which
    /// brings its own space).
    public var isAttached = false
    /// Stays on the previous unit's line: closing punctuation, or what follows an opening mark.
    public var staysWithPrevious = false

    /// The Reading's units, in order. Pass-through text keeps its line breaks and is split at spaces
    /// so it can wrap; full-width marks are split from the English around them.
    public static func all(in segments: [Segment]) -> [ReadingUnit] {
        var units: [ReadingUnit] = []
        var previous: Edge = .none
        for (index, segment) in segments.enumerated() {
            if segment.isWord {
                units.append(ReadingUnit(kind: .word(segment), isAttached: previous.attachesNext, staysWithPrevious: previous == .opening))
                previous = .han
                continue
            }
            let afterWord = index > 0 && segments[index - 1].isWord
            let beforeWord = index + 1 < segments.count && segments[index + 1].isWord
            for token in tokens(of: segment.original, afterHan: afterWord, beforeHan: beforeWord) {
                switch token {
                case .space:
                    previous = previous == .none ? .none : .space
                case .newline:
                    units.append(ReadingUnit(kind: .lineBreak))
                    previous = .none
                case .run(let text, let face):
                    let closes = text.allSatisfy(closing.contains)
                    let follows = previous != .none && previous != .space
                    let latinOnLatin = previous == .latin && face == .latin
                    let fullWidth = face == .han
                    let stays = follows && (closes || previous == .opening)
                    units.append(ReadingUnit(
                        kind: .text(text, face),
                        isAttached: follows && (closes || fullWidth || latinOnLatin || previous.attachesNext),
                        staysWithPrevious: stays
                    ))
                    if let last = text.last, opening.contains(last) {
                        previous = .opening
                    } else {
                        previous = fullWidth ? .fullWidthMark : .latin
                    }
                }
            }
        }
        return units
    }

    /// What the unit before ended with.
    private enum Edge {
        case none, space, han, latin, fullWidthMark, opening

        var attachesNext: Bool { self == .fullWidthMark || self == .opening }
    }

    private enum Token {
        case run(String, ReadingFace)
        case space
        case newline
    }

    private static let closing = Set("，。、！？；：,.!?;:)）」』】》〉”’…%")
    private static let opening = Set("@#（(「『【《〈“‘")
    /// Marks Chinese and English share a code point for; they follow the text they touch.
    private static let shared = Set("“”‘’…—·")

    private static func isFullWidthMark(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x3001...0x303F).contains($0.value) || (0xFF01...0xFF60).contains($0.value) }
    }

    /// Pass-through text as runs of one face, spaces and line breaks.
    private static func tokens(of text: String, afterHan: Bool, beforeHan: Bool) -> [Token] {
        let characters = Array(text)
        var faces: [ReadingFace] = characters.map { isFullWidthMark($0) ? .han : .latin }
        for index in characters.indices where shared.contains(characters[index]) {
            let before = index > 0 ? faces[index - 1] == .han : afterHan
            if before { faces[index] = .han }
        }
        for index in characters.indices.reversed() where shared.contains(characters[index]) {
            let after = index + 1 < characters.count ? faces[index + 1] == .han : beforeHan
            if after { faces[index] = .han }
        }
        var tokens: [Token] = []
        var run = ""
        var runFace = ReadingFace.latin
        func flush() {
            if !run.isEmpty { tokens.append(.run(run, runFace)) }
            run = ""
        }
        for (character, face) in zip(characters, faces) {
            if character.isNewline {
                flush()
                tokens.append(.newline)
            } else if character.isWhitespace {
                flush()
                tokens.append(.space)
            } else {
                // An opening mark starts a run of its own, so the text before it can end the line.
                let splits = face != runFace || (face == .han && (opening.contains(character) || run.last.map(opening.contains) == true))
                if splits { flush() }
                runFace = face
                run.append(character)
            }
        }
        flush()
        return tokens
    }
}
