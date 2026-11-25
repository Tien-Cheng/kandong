import SwiftUI
import KandongKit

/// The Reading of a whole text. Click a word (or use ←/→) to see what it means in the word card.
struct ReadingView: View {
    let model: AppModel
    let controller: ResultPanelController
    let analysis: OfflineAnalysis
    let showTraditional: Bool

    var body: some View {
        let settings = model.settings
        ReadingBlock(
            content: ReadingContent(
                segments: analysis.segments, style: .short, typeface: settings.readingTypeface, showTraditional: showTraditional,
                withoutPinyin: settings.pinyinForUnknownOnly ? Set(analysis.words.filter(model.isKnown).map(\.id)) : [],
                saved: model.savedWords
            ),
            selectedID: controller.selectedWordID,
            actions: controller
        )
    }
}

extension ResultPanelController: ReadingBlockActions {
    func select(_ segment: Segment) {
        selectedWordID = selectedWordID == segment.id ? nil : segment.id
    }

    func menu(for segment: Segment?) -> [ReadingMenuItem] {
        guard let segment, let analysis = model.session?.analysis else { return [] }
        return [
            .action("Say \(segment.text)") { Speech.speak(segment.text) },
            .action(model.isSaved(segment.text) ? "Remove from Vocabulary" : "Save to Vocabulary") { [model] in
                model.toggleSaved(segment, sentence: analysis.source)
            },
            .separator,
            .action("Copy \(segment.text)") { Pasteboard.copy(segment.text) },
            .action("Copy Text") { Pasteboard.copy(analysis.source) },
        ]
    }

    func register(_ view: ReadingBlockView) {
        readingBlocks.add(view)
    }
}
