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
            passage: nil,
            actions: controller
        )
    }
}

extension ResultPanelController: ReadingBlockActions {
    func select(_ segment: Segment) {
        selectedWordID = selectedWordID == segment.id ? nil : segment.id
    }

    func menu(for segment: Segment?, in passage: Int?) -> [ReadingMenuItem] {
        guard let session = model.session, let analysis = session.analysis else { return [] }
        var items: [ReadingMenuItem] = []
        if let segment {
            items = [
                .action("Say \(segment.text)") { Speech.speak(segment.text) },
                .action(model.isSaved(segment.text) ? "Remove from Vocabulary" : "Save to Vocabulary") { [model] in
                    model.toggleSaved(segment, sentence: session.sentence(of: segment))
                },
                .separator,
                .action("Copy \(segment.text)") { Pasteboard.copy(segment.text) },
            ]
        }
        if let state = passage.flatMap({ session.passage($0) }) {
            let chinese = state.segments.map(\.original).joined()
            if segment != nil { items.append(.separator) }
            items.append(.action("Say Passage") { Speech.speak(chinese) })
            items.append(.action("Copy Passage") { Pasteboard.copy(chinese) })
            if let translation = state.translation, session.direction == .learn {
                items.append(.action("Copy Passage’s Translation") { Pasteboard.copy(translation) })
            }
        } else {
            items.append(.action("Copy Text") { Pasteboard.copy(analysis.source) })
        }
        return items
    }

    func register(_ view: ReadingBlockView) {
        readingBlocks.add(view)
    }
}
