import Foundation
import Observation
import KandongKit

/// One passage of a long text. Each is its own observable, so the one being translated updates alone.
@MainActor
@Observable
final class PassageState: Identifiable {
    enum Status { case waiting, translating, done, missing }

    let passage: Passage
    /// Whether it has anything to translate; a URL, say, is shown once, as it is.
    let needsTranslation: Bool
    /// The Reading: of the passage, or (Reverse) of its Chinese once that's in.
    var segments: [Segment] = []
    /// Learn: its English. Reverse: its Chinese.
    var translation: String?
    var status = Status.waiting
    var explanation = ""
    var isExplaining = false
    var isThinking = false
    var explanationError: String?

    nonisolated var id: Int { passage.id }

    init(_ passage: Passage, direction: Direction) {
        self.passage = passage
        needsTranslation = LookupEngine.needsTranslation(passage, direction)
        if !needsTranslation { status = .done }
    }

    var hasWords: Bool { segments.contains(where: \.isWord) }
    var isExplained: Bool { !explanation.isEmpty || isExplaining }
}

/// Everything the panel shows for one Lookup, filled in as each step finishes.
@MainActor
@Observable
final class LookupSession: Identifiable {
    enum Status: Equatable {
        case readingImage
        case translating
        case done
        case failed(String)
    }

    let id = UUID()
    var source: LookupSource
    var direction: Direction = .learn
    /// The text the user looked up (for Reverse, the English).
    var sourceText = ""
    /// The Chinese being studied: the source text for Learn, the AI's Chinese for Reverse.
    var analysis: OfflineAnalysis? {
        didSet {
            words = analysis?.words ?? []
            uniqueWords = analysis?.uniqueWords ?? []
            for analysed in analysis?.passages ?? [] {
                guard let state = passages.first(where: { $0.id == analysed.id }), let segments = analysis?.segments(of: analysed),
                      state.segments != segments else { continue }
                state.segments = segments
            }
            positions = Dictionary(words.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }
    /// Long text's passages; empty when it's shown whole.
    private(set) var passages: [PassageState] = []
    /// The Reading's words, in order, and the Word breakdown's, kept from `analysis`.
    private(set) var words: [Segment] = []
    private(set) var uniqueWords: [Segment] = []
    /// Where each word is in `words`, by Segment id.
    @ObservationIgnored private(set) var positions: [Int: Int] = [:]
    var translation: String?
    /// Register remark for Reverse Lookups.
    var note: String?
    var status: Status = .translating
    /// The Backend answering this Lookup, as it was when the Lookup started.
    var backend = BackendConfig.appleIntelligence
    var backendID: String { backend.id }
    /// The Backend the user picked for Explain instead, if any; later parts keep using it.
    var explanationBackend: BackendConfig?
    /// The image, for image Lookups, so another Backend can read it again.
    var image: Data?
    var backendLabel = ""
    /// Whether the Backend keeps text on this Mac (shown in the badge).
    var backendIsLocal = false
    var showTraditional = false
    var historyID: Int64?
    /// Only the Chinese is known by passage (an old Reverse entry in History).
    var hidesSourcePassages = false
    /// Shown again from History: the stored Translation with the dictionary's readings.
    var isReopened = false
    /// Whether the panel may ask about opening at login: the question about My level was answered before.
    var mayAskOpenAtLogin = false
    /// Message shown instead of a Result (e.g. "No selection").
    var message: String?

    /// Set while a text too long for the Backend is translated in parts.
    var progress: LookupProgress?
    /// The model is thinking before it writes the Translation.
    var isThinking = false

    var explanation = ""
    var isExplaining = false
    var isExplanationThinking = false
    var explanationError: String?
    /// A long text is explained one part at a time; nil until the first Explain.
    var explanationParts: ExplanationParts?

    /// Whether some of the text is still to be explained (or a part failed and can be retried).
    var hasMoreToExplain: Bool {
        guard !isExplaining, let parts = explanationParts else { return false }
        return !parts.isFinished && !explanation.isEmpty
    }

    // MARK: Passages

    func split(into passages: [Passage]) {
        self.passages = passages.map { PassageState($0, direction: direction) }
    }

    var isLong: Bool { !passages.isEmpty }

    func passage(_ id: Int) -> PassageState? { passages.first { $0.id == id } }

    /// The passage a word is in, by Segment id.
    func passage(containing wordID: Int) -> PassageState? {
        passages.first { $0.segments.contains { $0.id == wordID } }
    }

    /// Passages still to translate.
    var untranslated: [PassageState] { passages.filter { $0.status != .done } }

    /// The whole Translation (Reverse: the Chinese), of the passages that have one.
    var joinedTranslation: String {
        let texts = Dictionary(uniqueKeysWithValues: passages.map { ($0.id, $0.translation ?? ($0.needsTranslation ? "" : $0.passage.text)) })
        return Passage.join(passages.map(\.passage), spaced: direction == .learn) { texts[$0.id] ?? "" }
    }

    /// The sentence a word is in, to save with it.
    func sentence(of word: Segment) -> String {
        analysis?.sentence(containing: word.id) ?? chineseText
    }

    @ObservationIgnored var tasks: [Task<Void, Never>] = []

    init(source: LookupSource) {
        self.source = source
    }

    /// Mixed Chinese and English, which can be read as it is or said all in Chinese.
    var canFlip: Bool {
        !sourceText.isEmpty && Direction.isMixed(sourceText)
    }

    /// Text sent to Explain: always the Chinese.
    var chineseText: String {
        analysis?.source ?? sourceText
    }

    func cancel() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }
}
