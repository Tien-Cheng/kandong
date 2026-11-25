import Foundation

/// One block of a long text: a paragraph, or part of a long one, short enough to be shown with its
/// Translation beneath it.
public struct Passage: Hashable, Codable, Sendable, Identifiable {
    public var id: Int
    /// The text without the line breaks a screenshot or PDF wrapped it at.
    public var text: String
    /// The whitespace between it and the passage before, so joining passages keeps the paragraphs.
    public var leading: String

    public init(id: Int, text: String, leading: String) {
        self.id = id
        self.text = text
        self.leading = leading
    }

    public var startsParagraph: Bool { id == 0 || leading.contains(where: \.isNewline) }
    /// A blank line comes before it.
    public var startsSection: Bool { leading.count(where: \.isNewline) > 1 }
    /// About one line long, as in a chat, lyrics or a list, rather than a paragraph.
    public var isLine: Bool { Self.weight(text) <= 30 }

    // MARK: Splitting

    /// About how much Chinese a passage holds: with its Translation it fits the panel without scrolling.
    static let target = 120.0
    /// A paragraph a little over the target stays whole.
    static let limit = 150.0

    /// Length in Chinese characters; English takes about two and a half letters to say as much.
    static func weight(_ text: some StringProtocol) -> Double {
        text.reduce(0) { $0 + ($1.isWhitespace ? 0 : $1.isASCII ? 0.4 : 1) }
    }

    /// The text in passages, or none when it is short enough to show whole.
    public static func split(_ text: String) -> [Passage] {
        guard weight(text) > target else { return [] }
        var passages: [Passage] = []
        for paragraph in paragraphs(text) {
            var leading = paragraph.leading
            for piece in pieces(paragraph.text) {
                let body = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                passages.append(Passage(id: passages.count, text: body, leading: passages.isEmpty ? "" : leading))
                leading = String(piece.reversed().prefix { $0.isWhitespace }.reversed())
            }
        }
        return passages.count > 1 ? passages : []
    }

    /// Passages put back together, as their own text or as `text` gives it. A space goes between
    /// English passages of one paragraph; Chinese needs none.
    public static func join(_ passages: [Passage], spaced: Bool = false, text: (Passage) -> String) -> String {
        var result = ""
        for passage in passages {
            let body = text(passage)
            guard !body.isEmpty else { continue }
            if !result.isEmpty { result += passage.startsParagraph ? passage.leading : (spaced ? " " : passage.leading) }
            result += body
        }
        return result
    }

    /// Lines, with the ones a screenshot or PDF broke mid-sentence put back together, and the gap
    /// before each.
    static func paragraphs(_ text: String) -> [(text: String, leading: String)] {
        var result: [(text: String, leading: String)] = []
        var block: [String] = []
        var gap = ""
        func flush() {
            let widest = block.map(columns).max() ?? 0
            // Wrapped text fills every line but a paragraph's last, and its sentences end wherever they
            // fall, mid-line too. Otherwise the lines are the author's: a chat, a list, a poem, lyrics.
            let fills: (String) -> Bool = { columns($0) * 4 >= widest * 3 }
            let isWrapped = block.count >= 3 && widest >= 30 && block.dropLast().allSatisfy { fills($0) || endsSentence($0) }
                && block.contains { TextChunker.sentences($0).count > 1 }
            var current = ""
            for (index, line) in block.enumerated() {
                current += current.isEmpty ? line : separator(between: current, and: line) + line
                let next = index + 1 < block.count ? block[index + 1] : nil
                if let next, isWrapped, fills(line), !endsSentence(line), !startsItem(next) { continue }
                result.append((current, gap))
                gap = "\n"
                current = ""
            }
            block = []
        }
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            // Trailing spaces mean nothing; leading ones (full-width indents) mark a paragraph.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
                if !result.isEmpty { gap = "\n\n" }
            } else {
                block.append(line.first == "\u{3000}" ? "\u{3000}" + trimmed : trimmed)
            }
        }
        flush()
        return result.map { ($0.text.trimmingCharacters(in: .whitespaces), $0.leading) }
    }

    private static func columns(_ line: String) -> Int {
        line.reduce(0) { $0 + ($1.isASCII ? 1 : 2) }
    }

    private static let sentenceEnds = Set("。！？；…!?.:：;")
    private static let closers = Set("”’」』）)\"'】》")

    private static func endsSentence(_ line: String) -> Bool {
        line.reversed().first { !closers.contains($0) }.map(sentenceEnds.contains) ?? false
    }

    /// A list item, a chat line's @name, a heading's # or an indented paragraph; or an English line with
    /// a capital, which starts a verse more often than it carries a sentence on with a name.
    private static func startsItem(_ line: String) -> Bool {
        line.range(of: #"^([A-Z][a-z’' ]|[(\[]|\x{3000}|[-•*·>@#]|[（(]?[0-9一二三四五六七八九十]+[.、)）])"#, options: .regularExpression) != nil
    }

    private static func separator(between line: String, and next: String) -> String {
        let latin: (Character?) -> Bool = { $0.map { $0.isASCII && !$0.isWhitespace } ?? false }
        return latin(line.last) && latin(next.first) ? " " : ""
    }

    /// A paragraph cut at sentence ends near the target; sentences that are too long at clauses.
    static func pieces(_ paragraph: String) -> [String] {
        guard weight(paragraph) > limit else { return [paragraph] }
        // Each unit is looked at once; what can't be cut (a long URL) stays whole.
        var units: [String] = []
        var remaining = Array(TextChunker.sentences(paragraph).reversed())
        while let unit = remaining.popLast() {
            let smaller = weight(unit) > limit ? TextChunker.smaller(unit) : []
            if smaller.count > 1 { remaining.append(contentsOf: smaller.reversed()) } else { units.append(unit) }
        }
        var pieces: [String] = []
        for unit in units {
            let together = weight(pieces.last ?? "") + weight(unit)
            if !pieces.isEmpty, together <= target || (weight(unit) < 12 && together <= limit) {
                pieces[pieces.count - 1] += unit
            } else {
                pieces.append(unit)
            }
        }
        // A short tail reads better with what it ends.
        if pieces.count > 1, let tail = pieces.last, weight(tail) < 30, weight(pieces[pieces.count - 2]) + weight(tail) <= limit {
            pieces.removeLast()
            pieces[pieces.count - 1] += tail
        }
        return pieces
    }
}

/// How far a long Lookup's Translation has got.
public struct PassageProgress: Equatable, Sendable {
    /// By passage id; the last one may still be coming in.
    public var texts: [Int: String]
    /// The passage still coming in.
    public var current: Int?
}

public typealias PassageHandler = @Sendable (PassageProgress) async -> Void

/// What a long Lookup's Translation came to. Passages that were translated are kept whatever
/// happened to the others.
public struct PassageReplies: Sendable {
    public var texts: [Int: String] = [:]
    /// Reverse: the first register remark.
    public var note = ""
    var corrections: [LearnReply.ReadingCorrection] = []
    /// Why some are missing, when it wasn't just the model leaving them out.
    public var error: Error?
}
