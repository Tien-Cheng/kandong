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
    public func learn(_ analysis: OfflineAnalysis, backend: AIBackend) async throws -> (translation: String, analysis: OfflineAnalysis) {
        let text = analysis.source
        let request = Prompts.learn(
            text: text, analysis: analysis, context: workspace.context(), terms: workspace.matchingTerms(in: text),
            askForReadings: backend.correctsReadings
        )
        let reply = try Prompts.parseLearn(try await backend.complete(request))
        return (reply.translation, applyCorrections(reply.readingCorrections, to: analysis))
    }

    /// Asks the Backend how to say English text in Chinese, then analyses that Chinese.
    public func reverse(_ text: String, backend: AIBackend) async throws -> (reply: ReverseReply, analysis: OfflineAnalysis) {
        let request = Prompts.reverse(text: text, context: workspace.context(), terms: workspace.matchingTerms(in: text))
        let reply = try Prompts.parseReverse(try await backend.complete(request))
        return (reply, analyzer.analyze(reply.chinese))
    }

    public func explain(_ text: String, translation: String?, backend: AIBackend) -> AsyncThrowingStream<String, Error> {
        backend.respond(to: Prompts.explain(
            text: text, translation: translation, context: workspace.context(), terms: workspace.matchingTerms(in: text)
        ))
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
