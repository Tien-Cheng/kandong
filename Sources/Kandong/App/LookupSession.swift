import Foundation
import Observation
import KandongKit

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
    var analysis: OfflineAnalysis?
    var translation: String?
    /// Register remark for Reverse Lookups.
    var note: String?
    var status: Status = .translating
    var backendLabel = ""
    /// Whether the Backend keeps text on this Mac (shown in the badge).
    var backendIsLocal = false
    /// Whether the user asked for the Local backend (⇧).
    var usesLocalBackend = false
    var showTraditional = false
    var historyID: Int64?
    /// Message shown instead of a Result (e.g. "No selection").
    var message: String?

    var explanation = ""
    var isExplaining = false
    var explanationError: String?

    @ObservationIgnored var tasks: [Task<Void, Never>] = []

    init(source: LookupSource) {
        self.source = source
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
