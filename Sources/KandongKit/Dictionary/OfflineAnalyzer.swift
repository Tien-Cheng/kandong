import Foundation

/// Produces the instant Reading and Word breakdown for a text, using only on-device data.
///
/// Segmentation and context-dependent readings (了 le/liǎo, 得 de/děi, 行 xíng/háng) come from the
/// system's Chinese tokenizer; CC-CEDICT supplies citation-tone pinyin and glosses and repairs the
/// tokenizer's occasional bad splits (沟 + 通过 → 沟通 + 过). Traditional text is segmented through
/// its Simplified form and keeps its original characters.
public final class OfflineAnalyzer: Sendable {
    public let dictionary: CEDict
    public let hsk: HSKTable

    public init(dictionary: CEDict, hsk: HSKTable) {
        self.dictionary = dictionary
        self.hsk = hsk
    }

    public func analyze(_ source: String) -> OfflineAnalysis {
        let simplified = source.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? source
        let simplifiedNS = simplified as NSString
        // Hant→Hans maps character for character; if lengths ever differ we drop the original form.
        let originalNS = (simplifiedNS.length == (source as NSString).length ? source : simplified) as NSString

        var pieces: [Piece] = []
        for token in tokenize(simplified) {
            let text = simplifiedNS.substring(with: token.range)
            let original = originalNS.substring(with: token.range)
            if text.allSatisfy(\.isHan) {
                pieces.append(contentsOf: hanPieces(text: text, original: original, transcription: token.transcription))
            } else if text.containsHan {
                pieces.append(contentsOf: splitMixed(text: text, original: original))
            } else {
                pieces.append(Piece(text: text, original: original, isHan: false, syllables: nil))
            }
        }
        pieces = mergeAddOnWords(repairSplits(pieces))
        return OfflineAnalysis(source: source, segments: buildSegments(pieces))
    }

    // MARK: - Tokenizing

    private struct Token {
        var range: NSRange
        var transcription: String?
    }

    /// Word tokens from the system tokenizer, with the gaps between them (spaces etc.) as tokens too.
    private func tokenize(_ text: String) -> [Token] {
        let cfText = text as CFString
        let length = CFStringGetLength(cfText)
        guard length > 0 else { return [] }
        let tokenizer = CFStringTokenizerCreate(
            nil, cfText, CFRangeMake(0, length), kCFStringTokenizerUnitWordBoundary,
            Locale(identifier: "zh-Hans") as CFLocale
        )
        var tokens: [Token] = []
        var cursor = 0
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if range.location > cursor {
                tokens.append(Token(range: NSRange(location: cursor, length: range.location - cursor)))
            }
            let transcription = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription
            ) as? String
            tokens.append(Token(range: NSRange(location: range.location, length: range.length), transcription: transcription))
            cursor = range.location + range.length
        }
        if cursor < length {
            tokens.append(Token(range: NSRange(location: cursor, length: length - cursor)))
        }
        return tokens
    }

    // MARK: - Pieces

    /// A provisional word or pass-through run, before dictionary lookup.
    private struct Piece {
        var text: String
        var original: String
        var isHan: Bool
        /// One tokenizer syllable per character, when the transcription could be aligned.
        var syllables: [Syllable]?
    }

    private func hanPieces(text: String, original: String, transcription: String?) -> [Piece] {
        let syllables = transcription.flatMap { align(text: text, transcription: $0) }
        if text.count == 1 || dictionary.contains(text) {
            return [Piece(text: text, original: original, isHan: true, syllables: syllables)]
        }
        // Unknown multi-character token: split into dictionary words.
        var pieces: [Piece] = []
        var offset = 0
        let originalChars = Array(original)
        for word in splitIntoDictionaryWords(text) {
            let range = offset..<(offset + word.count)
            pieces.append(Piece(
                text: word,
                original: String(originalChars[range]),
                isHan: true,
                syllables: syllables.map { Array($0[range]) }
            ))
            offset += word.count
        }
        return pieces
    }

    private func splitMixed(text: String, original: String) -> [Piece] {
        var pieces: [Piece] = []
        let chars = Array(text), originalChars = Array(original)
        var start = 0
        while start < chars.count {
            let isHan = chars[start].isHan
            var end = start
            while end < chars.count, chars[end].isHan == isHan { end += 1 }
            let run = String(chars[start..<end]), originalRun = String(originalChars[start..<end])
            if isHan {
                pieces.append(contentsOf: hanPieces(text: run, original: originalRun, transcription: nil))
            } else {
                pieces.append(Piece(text: run, original: originalRun, isHan: false, syllables: nil))
            }
            start = end
        }
        return pieces
    }

    /// Fewest-words split of a Han run using CC-CEDICT; unknown characters stand alone.
    func splitIntoDictionaryWords(_ text: String) -> [String] {
        let chars = Array(text)
        let n = chars.count
        var best = [Double](repeating: .infinity, count: n + 1)
        var back = [Int](repeating: 0, count: n + 1)
        best[0] = 0
        for end in 1...n {
            for length in 1...min(dictionary.maxWordLength, end) {
                let word = String(chars[(end - length)..<end])
                guard length == 1 || dictionary.contains(word) else { continue }
                let cost = best[end - length] + wordCost(word)
                if cost < best[end] {
                    best[end] = cost
                    back[end] = length
                }
            }
        }
        var words: [String] = []
        var end = n
        while end > 0 {
            words.append(String(chars[(end - back[end])..<end]))
            end -= back[end]
        }
        return words.reversed()
    }

    /// Lower is more plausible as a word: common HSK words are cheap, unknown single characters dear.
    private func wordCost(_ word: String) -> Double {
        if let info = hsk.info(for: word) { return log(Double(max(info.frequencyRank, 2))) }
        if dictionary.contains(word) { return 11 }
        return 14
    }

    /// Fixes the tokenizer's habit of attaching a character to the wrong neighbour, e.g. 沟|通过 → 沟通|过.
    private func repairSplits(_ pieces: [Piece]) -> [Piece] {
        var result = pieces
        var i = 0
        while i + 1 < result.count {
            let a = result[i], b = result[i + 1]
            guard a.isHan, b.isHan, a.text.count == 1, b.text.count >= 2 else { i += 1; continue }
            let bChars = Array(b.text), bOriginal = Array(b.original)
            let merged = a.text + String(bChars[0])
            let rest = String(bChars.dropFirst())
            guard dictionary.contains(merged), rest.count == 1 || dictionary.contains(rest) else { i += 1; continue }
            let before = wordCost(a.text) + wordCost(b.text)
            let after = wordCost(merged) + wordCost(rest)
            guard after + 0.5 < before else { i += 1; continue }
            let syllables: [Syllable]? = {
                guard let sa = a.syllables, let sb = b.syllables else { return nil }
                return sa + sb
            }()
            result[i] = Piece(
                text: merged, original: a.original + String(bOriginal[0]), isHan: true,
                syllables: syllables.map { Array($0[0..<2]) }
            )
            result[i + 1] = Piece(
                text: rest, original: String(bOriginal.dropFirst()), isHan: true,
                syllables: syllables.map { Array($0.dropFirst(2)) }
            )
            i += 1
        }
        return result
    }

    /// Joins neighbouring words that make a word only an add-on dictionary has (多 + 摸 → 多摸), which
    /// the system tokenizer can't know. The longest such word wins. Words CC-CEDICT also has are left
    /// as the tokenizer split them, since it reads the context.
    private func mergeAddOnWords(_ pieces: [Piece]) -> [Piece] {
        guard dictionary.hasAddOns else { return pieces }
        var result: [Piece] = []
        var i = 0
        while i < pieces.count {
            var end: Int?
            var text = ""
            var j = i
            while j < pieces.count, pieces[j].isHan, text.count + pieces[j].text.count <= dictionary.maxWordLength {
                text += pieces[j].text
                if j > i, dictionary.isAddOnWord(text) { end = j }
                j += 1
            }
            guard let end else {
                result.append(pieces[i])
                i += 1
                continue
            }
            let run = pieces[i...end]
            let syllables = run.allSatisfy { $0.syllables != nil } ? run.flatMap { $0.syllables! } : nil
            result.append(Piece(text: run.map(\.text).joined(), original: run.map(\.original).joined(), isHan: true, syllables: syllables))
            i = end + 1
        }
        return result
    }

    // MARK: - Readings

    /// Splits a tokenizer transcription ("liǎojiě") into one syllable per character, using each
    /// character's dictionary readings to find the boundaries.
    func align(text: String, transcription: String) -> [Syllable]? {
        let letters = Array(transcription.precomposedStringWithCanonicalMapping.filter(\.isLetter))
        let folded = letters.map { Pinyin.folded(String($0)) }
        guard folded.allSatisfy({ $0.count == 1 }) else { return nil }
        let target = folded.joined()
        let chars = Array(text)
        if chars.count == 1 { return [Syllable(marked: String(letters))] }

        // Fast path: a dictionary entry spelled exactly like the transcription.
        if let entry = dictionary.entries(for: text).first(where: { $0.foldedPinyin == target }),
           entry.syllables.count == chars.count {
            return cut(letters, lengths: entry.syllables.map { Pinyin.folded($0.text).count })
        }

        // General case: depth-first match of per-character readings against the transcription.
        let options: [[Int]] = chars.map { char in
            Set(dictionary.entries(for: String(char)).map(\.foldedPinyin)).map(\.count).sorted(by: >)
        }
        var lengths: [Int] = []
        func search(_ charIndex: Int, _ position: Int) -> Bool {
            if charIndex == chars.count { return position == target.count }
            let candidates = Set(dictionary.entries(for: String(chars[charIndex])).map(\.foldedPinyin))
            for length in options[charIndex] where position + length <= target.count {
                let start = target.index(target.startIndex, offsetBy: position)
                let end = target.index(start, offsetBy: length)
                guard candidates.contains(String(target[start..<end])) else { continue }
                lengths.append(length)
                if search(charIndex + 1, position + length) { return true }
                lengths.removeLast()
            }
            return false
        }
        return search(0, 0) ? cut(letters, lengths: lengths) : nil
    }

    private func cut(_ letters: [Character], lengths: [Int]) -> [Syllable] {
        var syllables: [Syllable] = []
        var position = 0
        for length in lengths {
            syllables.append(Syllable(marked: String(letters[position..<(position + length)])))
            position += length
        }
        return syllables
    }

    // MARK: - Segments

    private func buildSegments(_ pieces: [Piece]) -> [Segment] {
        var segments: [Segment] = []
        for piece in pieces {
            if !piece.isHan {
                // Merge neighbouring pass-through runs ("@", "Xiao", " ", "Ming") into one.
                if let last = segments.last, last.kind == .passThrough {
                    segments[segments.count - 1].text += piece.text
                    segments[segments.count - 1].original += piece.original
                } else {
                    segments.append(Segment(id: segments.count, kind: .passThrough, text: piece.text, original: piece.original))
                }
                continue
            }
            segments.append(wordSegment(piece, id: segments.count))
        }
        return segments
    }

    private func wordSegment(_ piece: Piece, id: Int) -> Segment {
        let entry = dictionary.bestEntry(for: piece.text, reading: piece.syllables)
        let syllables: [Syllable]
        if let entry, entry.syllables.count == piece.text.count,
           piece.syllables.map({ Pinyin.folded(Pinyin.display($0)) == entry.foldedPinyin }) ?? true {
            // Dictionary citation tones (这个 zhè ge, not the tokenizer's zhègè).
            syllables = entry.syllables
        } else if let tokenizer = piece.syllables {
            syllables = tokenizer
        } else if let entry {
            syllables = entry.syllables
        } else {
            syllables = piece.text.map { char in
                Syllable(marked: String(char).applyingTransform(.mandarinToLatin, reverse: false) ?? "")
            }
        }
        let chosen = Pinyin.display(syllables)
        var alternatives: [String] = []
        for other in dictionary.entries(for: piece.text) where !other.isProperNoun {
            let reading = Pinyin.display(other.syllables)
            if reading.lowercased() != chosen.lowercased(), !alternatives.contains(reading) {
                alternatives.append(reading)
            }
        }
        var segment = Segment(
            id: id, kind: .word, text: piece.text, original: piece.original, syllables: syllables,
            definitions: entry?.source == nil ? entry?.definitions ?? [] : [], hskLevel: hsk.level(of: piece.text),
            alternativeReadings: alternatives
        )
        // Only senses read the way the word is read here: ETO's 重大 chóng dà "Chongqing University" isn't
        // 重大 zhòng dà "major".
        for addOn in dictionary.entries(for: piece.text) where Pinyin.display(addOn.syllables).lowercased() == chosen.lowercased() {
            guard let source = addOn.source else { continue }
            for text in addOn.definitions where !segment.addOnGlosses.contains(where: { $0.text == text }) {
                segment.addOnGlosses.append(AddOnGloss(source: source, text: text))
            }
        }
        return segment
    }
}
