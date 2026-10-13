import Foundation

/// Where a Lookup's text came from.
public enum LookupSource: String, Codable, Sendable {
    case selection
    case screenCapture
    case clipboard

    public var displayName: String {
        switch self {
        case .selection: "Selection"
        case .screenCapture: "Screen capture"
        case .clipboard: "Clipboard"
        }
    }
}

/// Learn (Chinese → English) or Reverse (English → Chinese).
public enum Direction: String, Codable, Sendable {
    case learn
    case reverse

    /// Text with any Chinese in it is read; anything else is said in Chinese.
    public static func of(_ text: String) -> Direction {
        text.containsHan ? .learn : .reverse
    }
}

/// A text explained one part at a time: the whole text unless it is too long for the Backend.
public struct ExplanationParts: Equatable, Sendable {
    public private(set) var parts: [String]
    /// How many parts have been explained.
    public private(set) var done = 0

    public init(_ parts: [String]) {
        self.parts = parts.filter { !$0.isEmpty }
    }

    public var count: Int { parts.count }
    public var current: String? { done < parts.count ? parts[done] : nil }
    public var isFinished: Bool { done >= parts.count }

    public mutating func finishCurrent() {
        done = min(done + 1, parts.count)
    }

    /// Replaces the current part with smaller ones after it didn't fit; false if it can't get smaller.
    public mutating func splitCurrent() -> Bool {
        guard let current else { return false }
        let sentences = TextChunker.sentences(current)
        let smaller: [String]
        if sentences.count > 1 {
            let middle = sentences.count / 2
            smaller = [sentences[..<middle].joined(), sentences[middle...].joined()]
        } else {
            smaller = TextChunker.smaller(current)
        }
        guard smaller.count > 1, smaller.allSatisfy({ !$0.isEmpty && $0.count < current.count }) else { return false }
        parts.replaceSubrange(done...done, with: smaller)
        return true
    }
}

/// How far a Lookup's Translation has got.
public struct LookupProgress: Equatable, Sendable {
    public var completedParts: Int
    /// 1 unless the text is sent in parts; nil while the Backend is still finding out how small the parts must be.
    public var totalParts: Int?
    /// The Translation so far, including the part still coming in.
    public var translation: String

    public var isInParts: Bool { totalParts != 1 }
}

public typealias ProgressHandler = @Sendable (LookupProgress) async -> Void
/// Hears that the model is thinking before it answers.
public typealias ThinkingHandler = @Sendable () async -> Void

/// The steps of a Lookup that don't involve the UI.
public struct LookupEngine: Sendable {
    public let analyzer: OfflineAnalyzer
    public let workspace: Workspace

    public init(analyzer: OfflineAnalyzer, workspace: Workspace) {
        self.analyzer = analyzer
        self.workspace = workspace
    }

    /// Instant, dictionary-only Reading and Word breakdown.
    public func offline(_ text: String) -> OfflineAnalysis {
        analyzer.analyze(text)
    }

    /// Asks the Backend for the Translation and reading corrections, and applies the corrections.
    /// Text too long for the Backend is sent without the optional parts of the prompt, and only as
    /// a last resort in parts; `progress` hears about each part.
    public func learn(
        _ analysis: OfflineAnalysis, backend: AIBackend, progress: ProgressHandler? = nil, thinking: ThinkingHandler? = nil
    ) async throws -> (translation: String, analysis: OfflineAnalysis) {
        let text = analysis.source
        let context = workspace.context()
        let parts = try await fitted(
            text, backend: backend, steps: steps(askForReadings: backend.correctsReadings, context: context), thinking: thinking,
            request: { part, preceding, step in
                Prompts.learn(
                    text: part, analysis: analysis, context: step.context(context), terms: workspace.matchingTerms(in: part),
                    askForReadings: step.askForReadings, preceding: preceding
                )
            },
            parse: { reply, part in
                let parsed = try Prompts.parseLearn(reply)
                if Self.isUntranslated(english: parsed.translation, source: part) { throw BackendError.untranslated }
                return parsed
            },
            progress: { replies, total, current in
                await progress?(LookupProgress(completedParts: replies.count, totalParts: total,
                                               translation: Self.join(replies.map { ($0.text, $0.reply.translation) }, separator: " ", then: current)))
            }
        )
        let translation = Self.join(parts.map { ($0.text, $0.reply.translation) }, separator: " ")
        return (translation, applyCorrections(parts.flatMap(\.reply.readingCorrections), to: analysis))
    }

    /// Asks the Backend how to say English text in Chinese, then analyses that Chinese.
    public func reverse(
        _ text: String, backend: AIBackend, progress: ProgressHandler? = nil, thinking: ThinkingHandler? = nil
    ) async throws -> (reply: ReverseReply, analysis: OfflineAnalysis) {
        let context = workspace.context()
        let parts = try await fitted(
            text, backend: backend, steps: steps(askForReadings: false, context: context), thinking: thinking,
            request: { part, preceding, step in
                Prompts.reverse(text: part, context: step.context(context), terms: workspace.matchingTerms(in: part), preceding: preceding)
            },
            parse: { reply, part in
                let parsed = try Prompts.parseReverse(reply)
                if !parsed.chinese.containsHan, Self.needsTranslation(english: part) { throw BackendError.untranslated }
                return parsed
            },
            progress: { replies, total, current in
                await progress?(LookupProgress(completedParts: replies.count, totalParts: total,
                                               translation: Self.join(replies.map { ($0.text, $0.reply.chinese) }, separator: "", then: current)))
            }
        )
        let reply = ReverseReply(
            chinese: Self.join(parts.map { ($0.text, $0.reply.chinese) }, separator: ""),
            note: parts.map(\.reply.note).first { !$0.isEmpty } ?? ""
        )
        return (reply, analyzer.analyze(reply.chinese))
    }

    public func explain(_ text: String, translation: String?, backend: AIBackend, thinking: ThinkingHandler? = nil) -> AsyncThrowingStream<String, Error> {
        var request = explainRequest(text, translation: translation)
        request.onThinking = thinking
        return backend.respond(to: request)
    }

    private func explainRequest(_ text: String, translation: String?) -> AIRequest {
        Prompts.explain(text: text, translation: translation, context: workspace.context(), terms: workspace.matchingTerms(in: text))
    }

    /// The parts to explain one at a time: the whole text unless the Backend says it won't fit.
    public func explanationParts(_ text: String, translation: String?, backend: AIBackend) async -> ExplanationParts {
        guard await backend.fits(explainRequest(text, translation: translation)) == false else { return ExplanationParts([text]) }
        let pieces = await TextChunker.pack(TextChunker.sentences(text)) { part, _ in
            await backend.fits(explainRequest(part, translation: nil)) ?? true
        }
        return ExplanationParts(pieces?.map(\.text) ?? [text])
    }


    // MARK: Fitting long text

    /// How much optional material a prompt carries; each later step carries less.
    struct PromptStep: Equatable {
        var askForReadings: Bool
        var contextLimit: Int?

        func context(_ context: String) -> String {
            contextLimit.map { Prompts.trimmed(context: context, limit: $0) } ?? context
        }
    }

    static let shortContextLimit = 400

    /// Whole prompt; then without the dictionary readings; then with Context trimmed.
    func steps(askForReadings: Bool, context: String) -> [PromptStep] {
        var steps = [PromptStep(askForReadings: askForReadings, contextLimit: nil)]
        if askForReadings { steps.append(PromptStep(askForReadings: false, contextLimit: nil)) }
        if context.count > Self.shortContextLimit { steps.append(PromptStep(askForReadings: false, contextLimit: Self.shortContextLimit)) }
        return steps
    }

    /// Sends the text whole with the first step that fits, else in the fewest, largest parts the
    /// last step allows, one after another. Backends that can't measure are tried and their
    /// parts halved until each one fits.
    func fitted<Reply: Sendable>(
        _ text: String,
        backend: AIBackend,
        steps: [PromptStep],
        thinking: ThinkingHandler? = nil,
        request: (_ part: String, _ preceding: String?, PromptStep) -> AIRequest,
        parse: (_ reply: String, _ part: String) throws -> Reply,
        progress: (_ done: [(text: String, reply: Reply)], _ total: Int?, _ current: String?) async -> Void
    ) async throws -> [(text: String, reply: Reply)] {
        var done: [(text: String, reply: Reply)] = []
        var total: Int? = 1

        // Sends one request, reporting the reply's `streamField` as it comes in.
        func ask(_ request: AIRequest, part: String) async throws -> Reply {
            var request = request
            request.onThinking = thinking
            var reply = ""
            var shown: String?
            for try await snapshot in backend.snapshots(of: request) {
                reply = snapshot
                guard let field = request.streamField,
                      let partial = PartialJSON.stringValue(of: field, in: Prompts.visibleText(snapshot)), partial != shown else { continue }
                shown = partial
                await progress(done, total, partial)
            }
            return try parse(reply, part)
        }

        var step = steps[steps.count - 1]
        var untranslated = false
        trying: for candidate in steps {
            let whole = request(text, nil, candidate)
            if await backend.fits(whole) == false { continue }
            do {
                return [(text, try await ask(whole, part: text))]
            } catch BackendError.contextTooLong {
                continue
            } catch BackendError.untranslated {
                // Small models sometimes copy a long text instead of translating it; shorter parts help.
                step = candidate
                untranslated = true
                break trying
            }
        }

        // Sends one part; if it still doesn't fit (or the Backend can't measure), halves it.
        func send(_ units: [String], preceding: String?) async throws {
            try Task.checkCancellation()
            let part = units.joined()
            do {
                done.append((part, try await ask(request(part, preceding, step), part: part)))
                total = total.map { max($0, done.count) }
                await progress(done, total, nil)
            } catch let error as BackendError where error == .contextTooLong || error == .untranslated {
                total = total.map { $0 + 1 }
                try await split(units, preceding: preceding, error: error)
            }
        }

        func split(_ units: [String], preceding: String?, error: BackendError = .contextTooLong) async throws {
            let smaller = units.count > 1 ? units : TextChunker.smaller(units.joined())
            guard smaller.count > 1 else { throw error }
            let middle = Self.balancedMiddle(smaller)
            try await send(Array(smaller[..<middle]), preceding: preceding)
            try await send(Array(smaller[middle...]), preceding: smaller[middle - 1])
        }

        guard !untranslated, await backend.fits(request(text, nil, step)) != nil else {
            // The Backend already failed on the whole text; start from its halves.
            total = nil
            await progress(done, total, nil)
            try await split(TextChunker.sentences(text), preceding: nil, error: untranslated ? .untranslated : .contextTooLong)
            return done
        }
        guard let pieces = await TextChunker.pack(TextChunker.sentences(text), fits: { part, preceding in
            await backend.fits(request(part, preceding, step)) ?? true
        }) else { throw BackendError.contextTooLong }
        total = pieces.count
        await progress(done, total, nil)
        for piece in pieces {
            try await send(TextChunker.sentences(piece.text), preceding: piece.preceding)
        }
        return done
    }

    /// Whether a reply didn't really translate its source:
    /// - it copied the Chinese, keeping at least half of the source's Chinese characters and adding
    ///   little English (a translation that quotes a sign or a name in Chinese adds plenty, so it passes);
    /// - or it summarised or dropped part of it: English runs two to four letters per Chinese
    ///   character, so a reply with fewer than 0.6 can't be the whole text.
    static func isUntranslated(english reply: String, source: String) -> Bool {
        let sourceHan = source.filter(\.isHan).count
        guard sourceHan >= 4 else { return false }
        let latin: (String) -> Int = { $0.filter { $0.isLetter && !$0.isHan }.count }
        let addedEnglish = latin(reply) - latin(source)
        let copied = reply.filter(\.isHan).count * 2 >= sourceHan && addedEnglish * 2 < sourceHan
        let cutShort = sourceHan >= 20 && addedEnglish * 5 < sourceHan * 3
        return copied || cutShort
    }

    /// Whether English has words to translate, beyond URLs, @mentions, #hashtags and numbers that are
    /// kept as they are.
    static func needsTranslation(english: String) -> Bool {
        english.split(whereSeparator: \.isWhitespace).contains { word in
            !(word.hasPrefix("@") || word.hasPrefix("#") || word.contains("://") || word.hasPrefix("www."))
                && word.contains(where: \.isLetter)
        }
    }

    /// Where to split units so both sides hold about half the characters.
    static func balancedMiddle(_ units: [String]) -> Int {
        let total = units.reduce(0) { $0 + $1.count }
        var running = 0
        for (index, unit) in units.enumerated() {
            running += unit.count
            if running * 2 >= total { return min(max(index + 1, 1), units.count - 1) }
        }
        return units.count / 2
    }

    /// Joins the replies for consecutive parts, keeping the source's line breaks between them, then
    /// the part still coming in.
    static func join(_ parts: [(source: String, reply: String)], separator: String, then current: String? = nil) -> String {
        var result = ""
        for (index, part) in parts.enumerated() {
            result += part.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard index < parts.count - 1 || current != nil else { break }
            let gap = part.source.reversed().prefix { $0.isWhitespace }
            result += gap.contains(where: \.isNewline) ? "\n" : separator
        }
        return result + (current ?? "")
    }

    /// Reads the text in an image with the Backend's vision model.
    public func transcribe(image: Data, backend: AIBackend) async throws -> String {
        Prompts.visibleText(try await backend.complete(Prompts.transcribe(image: image)))
    }

    /// Replaces dictionary readings the AI says are wrong in context, keeping the old one as an alternative.
    public func applyCorrections(_ corrections: [LearnReply.ReadingCorrection], to analysis: OfflineAnalysis) -> OfflineAnalysis {
        var result = analysis
        for correction in corrections {
            let word = correction.word.trimmingCharacters(in: .whitespaces)
            var syllables = correction.pinyin.split(whereSeparator: { $0 == " " || $0 == "'" }).map { Syllable(marked: String($0)) }
            if syllables.count != word.count, let aligned = analyzer.align(text: word, transcription: correction.pinyin) {
                syllables = aligned
            }
            guard !syllables.isEmpty else { continue }
            for index in result.segments.indices where result.segments[index].isWord
                && (result.segments[index].text == word || result.segments[index].original == word) {
                let old = result.segments[index]
                guard Pinyin.display(syllables).lowercased() != old.pinyin.lowercased() else { continue }
                result.segments[index].syllables = syllables
                result.segments[index].readingCorrected = true
                result.segments[index].alternativeReadings = [old.pinyin] + old.alternativeReadings.filter {
                    $0.lowercased() != Pinyin.display(syllables).lowercased()
                }
            }
        }
        return result
    }
}
