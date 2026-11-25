import Foundation

/// Where a Lookup's text came from.
public enum LookupSource: String, Codable, Sendable {
    case selection
    case screenCapture
    case clipboard
    /// Sent by another app or script through a `kandong://lookup` link.
    case otherApp
    /// Looked up again from History in the main window.
    case history
    /// A Vocabulary word's sentence, looked up from the main window.
    case vocabulary

    public var displayName: String {
        switch self {
        case .selection: "Selection"
        case .screenCapture: "Screen capture"
        case .clipboard: "Clipboard"
        case .otherApp: "Other app"
        case .history: "History"
        case .vocabulary: "Vocabulary"
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

    /// Chinese mixed with English worth translating, which the user may want either way: read as it
    /// is, or said all in Chinese.
    public static func isMixed(_ text: String) -> Bool {
        text.containsHan && LookupEngine.needsTranslation(english: String(text.map { $0.isHan ? " " : $0 }))
    }

    public var flipped: Direction { self == .learn ? .reverse : .learn }
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

    public init(completedParts: Int, totalParts: Int?, translation: String) {
        self.completedParts = completedParts
        self.totalParts = totalParts
        self.translation = translation
    }

    public var isInParts: Bool { totalParts != 1 }
}

public typealias ProgressHandler = @Sendable (LookupProgress) async -> Void
/// Hears that the model is thinking before it answers.
public typealias ThinkingHandler = @Sendable () async -> Void

/// Spaces out the reports of a reply coming in: each one reads the whole reply again and redraws the
/// panel, and a fast Backend sends hundreds a second.
struct Pace {
    static let interval = Duration.milliseconds(80)
    private var last: ContinuousClock.Instant?

    mutating func isDue(now: ContinuousClock.Instant = .now) -> Bool {
        if let last, now - last < Self.interval { return false }
        last = now
        return true
    }
}

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
        let passages = Passage.split(text)
        return passages.isEmpty ? analyzer.analyze(text) : analyzer.analyze(passages, source: text)
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
            text, backend: backend, steps: steps(askForReadings: backend.readingMode != .off, context: context), thinking: thinking,
            request: { part, preceding, step in
                Prompts.learn(
                    text: part, analysis: analysis, context: step.context(context), terms: workspace.matchingTerms(in: part),
                    readings: step.askForReadings ? backend.readingMode : .off, preceding: preceding
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
        // Only the kind of answer the Backend's mode asks for: a server that ignores the schema can't
        // slip free corrections past Choose or Off.
        switch backend.readingMode {
        case .off:
            return (translation, analysis)
        case .choose:
            return (translation, applyReadings(parts.reduce(into: [:]) { $0.merge($1.reply.readings) { first, _ in first } }, to: analysis))
        case .free:
            return (translation, applyCorrections(parts.flatMap(\.reply.readingCorrections), to: analysis))
        }
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
                var parsed = try Prompts.parseReverse(reply)
                parsed.chinese = Prompts.withoutFormatEcho(parsed.chinese, source: part)
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

    /// Asks the same Backend how the Chinese it wrote for `english` reads in context, in its Reading
    /// corrections mode, and applies the answer. A second, readings-only request: Choose can only
    /// offer the dictionary's readings once the Chinese exists. Nothing is asked when the mode is
    /// Off, no word has more than one reading, or the request doesn't fit; the dictionary's readings stand.
    public func contextReadings(_ analysis: OfflineAnalysis, english: String, backend: AIBackend) async throws -> OfflineAnalysis {
        guard let request = Prompts.readings(of: analysis, english: english, mode: backend.readingMode),
              await backend.fits(request) != false else { return analysis }
        let reply: LearnReply
        do {
            reply = try Prompts.parseReadings(try await backend.complete(request))
        } catch BackendError.contextTooLong {
            return analysis
        }
        // Only the kind of answer the mode asks for, as in `learn`.
        return backend.readingMode == .choose ? applyReadings(reply.readings, to: analysis) : applyCorrections(reply.readingCorrections, to: analysis)
    }

    // MARK: Passages

    /// Translates a long text's passages (those in `wanted`), keeping whatever could be translated.
    /// `analysis` comes back with the readings a Free Backend corrected; a Choose one is asked for them
    /// afterwards (`contextReadings(_:translations:backend:)`): asked for both at once, small models
    /// copy long Chinese instead of translating it, and take several times as long.
    public func learnPassages(
        _ analysis: OfflineAnalysis, wanted: [Passage], backend: AIBackend, progress: PassageHandler? = nil, thinking: ThinkingHandler? = nil
    ) async throws -> (replies: PassageReplies, analysis: OfflineAnalysis) {
        let all = analysis.passages.map(\.passage)
        let context = workspace.context()
        let replies = try await translated(
            wanted, of: all, direction: .learn, backend: backend, steps: steps(askForReadings: backend.readingMode == .free, context: context),
            request: { batch, preceding, step in
                var request = Prompts.learn(
                    passages: batch, count: all.count, analysis: analysis, context: step.context(context),
                    terms: workspace.matchingTerms(in: batch.map(\.text).joined(separator: "\n")),
                    askForCorrections: step.askForReadings, preceding: preceding
                )
                request.onThinking = thinking
                return request
            },
            isGood: { text, passage in !Self.isUntranslated(english: text, source: passage.text) },
            alone: { passage in
                // Too long for this Backend even by itself: its sentences, in parts.
                try await learn(analyzer.analyze(passage.text), backend: backend, thinking: thinking).translation
            },
            progress: progress
        )
        return (replies, backend.readingMode == .free ? applyCorrections(replies.corrections, to: analysis) : analysis)
    }

    /// Asks a Choose Backend how a long text's words read in context, a few passages at a time, once
    /// they're translated. `progress` gets the analysis after each request; a failure keeps the
    /// dictionary's readings for the rest.
    public func contextReadings(
        _ analysis: OfflineAnalysis, translations: [Int: String], backend: AIBackend, progress: @Sendable (OfflineAnalysis) async -> Void
    ) async throws {
        guard backend.readingMode == .choose else { return }
        var result = analysis
        let passages = analysis.passages.filter { translations[$0.id] != nil }
        for start in stride(from: 0, to: passages.count, by: Self.smallBatch) {
            try Task.checkCancellation()
            let batch = passages[start..<min(start + Self.smallBatch, passages.count)]
            let part = OfflineAnalysis(source: batch.map(\.passage.text).joined(separator: "\n"), segments: batch.flatMap { analysis.segments[$0.segments] })
            let english = batch.compactMap { translations[$0.id] }.joined(separator: "\n")
            guard let request = Prompts.readings(of: part, english: english, mode: .choose), await backend.fits(request) != false else { continue }
            let reply = try Prompts.parseReadings(try await backend.complete(request))
            result = applyReadings(reply.readings, to: result)
            await progress(result)
        }
    }

    /// Says a long English text's passages in Chinese, keeping whatever could be translated.
    public func reversePassages(
        _ wanted: [Passage], of all: [Passage], backend: AIBackend, progress: PassageHandler? = nil, thinking: ThinkingHandler? = nil
    ) async throws -> PassageReplies {
        let context = workspace.context()
        return try await translated(
            wanted, of: all, direction: .reverse, backend: backend, steps: steps(askForReadings: false, context: context),
            request: { batch, preceding, step in
                var request = Prompts.reverse(
                    passages: batch, count: all.count, context: step.context(context),
                    terms: workspace.matchingTerms(in: batch.map(\.text).joined(separator: "\n")), preceding: preceding
                )
                request.onThinking = thinking
                return request
            },
            isGood: { text, _ in text.containsHan },
            alone: { passage in try await reverse(passage.text, backend: backend, thinking: thinking).reply.chinese },
            progress: progress
        )
    }

    /// Whether a passage has anything to translate; the rest (a URL, say) is shown once, as it is.
    public static func needsTranslation(_ passage: Passage, _ direction: Direction) -> Bool {
        switch direction {
        case .learn: passage.text.containsHan
        case .reverse: needsTranslation(english: String(passage.text.map { $0.isHan ? " " : $0 }))
        }
    }

    /// Passages asked about at a time when the Backend left them out, or how they read: small models
    /// that can't do all of a long text manage a few.
    static let smallBatch = 4

    private func translated(
        _ wanted: [Passage], of all: [Passage], direction: Direction, backend: AIBackend, steps: [PromptStep],
        request: (_ batch: [Passage], _ preceding: String?, PromptStep) -> AIRequest,
        isGood: (_ text: String, Passage) -> Bool,
        alone: (Passage) async throws -> String,
        progress: PassageHandler?
    ) async throws -> PassageReplies {
        var result = PassageReplies()

        func preceding(_ batch: [Passage]) -> String? {
            batch.first.flatMap { first in all.last { $0.id < first.id }?.text }
        }

        /// Sends one batch and keeps the passages it translated; throws what stopped it from finishing.
        func ask(_ batch: [Passage], _ request: AIRequest) async throws {
            let byKey = Dictionary(uniqueKeysWithValues: batch.map { (Prompts.key(of: $0, count: all.count), $0) })
            let object = Prompts.passagesKey(direction)
            func clean(_ text: String) -> String {
                text.replacingOccurrences(of: #"^\s*\[p\d+\]\s*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var reply = ""
            func show() async {
                guard let progress else { return }
                var shown = PassageProgress(texts: result.texts)
                for value in PartialJSON.stringValues(inObject: object, in: Prompts.visibleText(reply)) {
                    guard let passage = byKey[value.key], !value.value.isEmpty else { continue }
                    shown.texts[passage.id] = clean(value.value)
                    // They're written in order, but not always listed in it.
                    shown.current = max(shown.current ?? 0, passage.id)
                }
                await progress(shown)
            }
            func keep(_ texts: [String: String]) {
                for (key, text) in texts {
                    guard let passage = byKey[key] else { continue }
                    let text = clean(text)
                    if !text.isEmpty, isGood(text, passage) { result.texts[passage.id] = text }
                }
            }
            do {
                var pace = Pace()
                for try await snapshot in backend.snapshots(of: request) {
                    reply = snapshot
                    if pace.isDue() { await show() }
                }
                let parsed = try Prompts.parsePassages(reply, direction)
                keep(parsed.texts)
                result.corrections += parsed.corrections
                if result.note.isEmpty { result.note = parsed.note }
                await progress?(PassageProgress(texts: result.texts))
            } catch {
                // Cut off or malformed: the passages it did finish still count, all but the last it wrote.
                let values = PartialJSON.stringValues(inObject: object, in: Prompts.visibleText(reply))
                let last = values.map(\.key).max()
                keep(Dictionary(values.filter { $0.isComplete && $0.key != last }.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first }))
                await progress?(PassageProgress(texts: result.texts))
                throw error
            }
        }

        /// Sends a batch that may be too big, in halves if it is.
        func send(_ batch: [Passage], _ step: PromptStep) async throws {
            try Task.checkCancellation()
            let prompt = request(batch, preceding(batch), step)
            do {
                if await backend.fits(prompt) == false { throw BackendError.contextTooLong }
                try await ask(batch, prompt)
            } catch BackendError.contextTooLong {
                let left = batch.filter { result.texts[$0.id] == nil }
                guard left.count > 1 else {
                    for passage in left {
                        let text = try await alone(passage)
                        if !text.isEmpty { result.texts[passage.id] = text }
                    }
                    await progress?(PassageProgress(texts: result.texts))
                    return
                }
                for half in halves(left) { try await send(half, step) }
            }
        }

        func halves(_ batch: [Passage]) -> [[Passage]] {
            guard batch.count > 1 else { return [batch] }
            let middle = Self.balancedMiddle(batch.map(\.text))
            return [Array(batch[..<middle]), Array(batch[middle...])]
        }

        do {
            // Whole if it fits, else without the optional parts of the prompt, else in batches.
            var step = steps[steps.count - 1]
            var inBatches = true
            trying: for candidate in steps {
                let whole = request(wanted, preceding(wanted), candidate)
                if await backend.fits(whole) == false { continue }
                do {
                    try await ask(wanted, whole)
                } catch BackendError.contextTooLong {
                    continue
                } catch let error where Self.canAskAgain(error) {
                    result.error = error
                }
                step = candidate
                inBatches = false
                break trying
            }
            if inBatches {
                // A Backend that can't measure has just turned it all away: halves, halved until they fit.
                let measures = await backend.fits(request(Array(wanted.prefix(1)), nil, step)) != nil
                let parts = measures ? await packed(wanted, fits: { await backend.fits(request($0, preceding($0), step)) ?? true }) : halves(wanted)
                for part in parts {
                    do {
                        try await send(part, step)
                    } catch let error where Self.canAskAgain(error) {
                        result.error = error
                    }
                }
            }
            // Once more for the ones it left out, copied or cut short, a few at a time.
            let missing = wanted.filter { result.texts[$0.id] == nil }
            if !missing.isEmpty { result.error = nil }
            for start in stride(from: 0, to: missing.count, by: Self.smallBatch) {
                do {
                    try await send(Array(missing[start..<min(start + Self.smallBatch, missing.count)]), steps[steps.count - 1])
                } catch let error where Self.canAskAgain(error) {
                    result.error = error
                }
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            result.error = error
        }
        if wanted.allSatisfy({ result.texts[$0.id] != nil }) { result.error = nil }
        return result
    }

    /// Whether the Backend may manage the rest after this: it answered, if badly. One that can't be
    /// reached, or turned the request away, isn't asked again.
    static func canAskAgain(_ error: Error) -> Bool {
        switch error as? BackendError {
        case .badResponse?, .untranslated?, .refused?, .cutOff?, .repeating?, .contextTooLong?: true
        default: false
        }
    }

    /// The largest consecutive batches that fit.
    private func packed(_ passages: [Passage], fits: ([Passage]) async -> Bool) async -> [[Passage]] {
        var remaining = passages[...]
        var batches: [[Passage]] = []
        while !remaining.isEmpty {
            var low = 1, high = remaining.count + 1
            while high - low > 1 {
                let middle = (low + high) / 2
                if await fits(Array(remaining.prefix(middle))) { low = middle } else { high = middle }
            }
            batches.append(Array(remaining.prefix(low)))
            remaining = remaining.dropFirst(low)
        }
        return batches
    }

    // MARK: Explain

    public func explain(_ text: String, translation: String?, backend: AIBackend, thinking: ThinkingHandler? = nil) -> AsyncThrowingStream<String, Error> {
        var request = explainRequest(text, translation: translation)
        request.onThinking = thinking
        return backend.respond(to: request)
    }

    private func explainRequest(_ text: String, translation: String?) -> AIRequest {
        Prompts.explain(
            text: text, translation: translation, context: workspace.context(), terms: workspace.matchingTerms(in: text),
            glossary: analyzer.dictionary.hasAddOns ? analyzer.analyze(text).uniqueWords : []
        )
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
            func show() async {
                guard let field = request.streamField,
                      let partial = PartialJSON.stringValue(of: field, in: Prompts.visibleText(reply)), partial != shown else { return }
                shown = partial
                await progress(done, total, partial)
            }
            var pace = Pace()
            for try await snapshot in backend.snapshots(of: request) {
                reply = snapshot
                if pace.isDue() { await show() }
            }
            await show()
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

    /// Uses the readings the AI chose for words with more than one (keyed by `ReadingChoice.key`),
    /// keeping the dictionary's as an alternative. Only the dictionary's own readings are taken, so a
    /// Backend that ignores the schema can't make one up.
    public func applyReadings(_ readings: [String: String], to analysis: OfflineAnalysis) -> OfflineAnalysis {
        var result = analysis
        for (key, reading) in readings {
            guard key.hasPrefix("w"), let id = Int(key.dropFirst()),
                  let index = result.segments.firstIndex(where: { $0.id == id && $0.isWord }) else { continue }
            let old = result.segments[index]
            // Tone marks matter (dé, děi, de), spacing and case don't.
            let same = { (a: String, b: String) in
                a.precomposedStringWithCanonicalMapping.lowercased().filter { !$0.isWhitespace }
                    == b.precomposedStringWithCanonicalMapping.lowercased().filter { !$0.isWhitespace }
            }
            guard !same(reading, old.pinyin), let match = old.alternativeReadings.first(where: { same($0, reading) }) else { continue }
            var syllables = match.split(separator: " ").map { Syllable(marked: String($0)) }
            if syllables.count != old.text.count, let aligned = analyzer.align(text: old.text, transcription: match) {
                syllables = aligned
            }
            guard !syllables.isEmpty else { continue }
            result.segments[index] = analyzer.reread(old, as: syllables)
            result.segments[index].readingCorrected = true
            result.segments[index].alternativeReadings = [old.pinyin] + old.alternativeReadings.filter { $0.lowercased() != match.lowercased() }
        }
        return result
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
                result.segments[index] = analyzer.reread(old, as: syllables)
                result.segments[index].readingCorrected = true
                result.segments[index].alternativeReadings = [old.pinyin] + old.alternativeReadings.filter {
                    $0.lowercased() != Pinyin.display(syllables).lowercased()
                }
            }
        }
        return result
    }
}
