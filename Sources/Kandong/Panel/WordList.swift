import SwiftUI
import KandongKit

/// The Word breakdown: new words, then (folded) the ones at or below My level.
struct WordList: View {
    let model: AppModel
    let controller: ResultPanelController
    let session: LookupSession
    @ViewState private var showAllWords = false

    private static let longTextThreshold = 1500

    var body: some View {
        let words = session.uniqueWords
        let known = words.filter(model.isKnown)
        let unknown = words.filter { !model.isKnown($0) }
        let isLong = session.sourceText.count > Self.longTextThreshold
        let shown = isLong && !showAllWords ? Array(unknown.prefix(40)) : unknown
        VStack(alignment: .leading, spacing: 2) {
            if !unknown.isEmpty {
                SectionTitle(known.isEmpty ? "Words" : "New words")
                    .padding(.bottom, 4)
            }
            rows(shown)
            if shown.count < unknown.count {
                Button("Show all \(unknown.count) words") { showAllWords = true }
                    .controlSize(.small)
                    .padding(.top, 4)
            }
            if !known.isEmpty {
                DisclosureGroup {
                    rows(known)
                } label: {
                    Text("\(known.count) known word\(known.count == 1 ? "" : "s") (up to \(HSKTable.label(for: model.settings.myLevel)))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
        }
    }

    private func rows(_ words: [Segment]) -> some View {
        let saved = model.savedWords
        let selected = controller.selectedWordID
        let typeface = model.settings.readingTypeface
        return LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(words) { word in
                WordRow(word: word, isSelected: word.id == selected, isSaved: saved.contains(word.text), typeface: typeface) {
                    controller.select(word)
                }
                .equatable()
            }
        }
    }
}

/// One word of the breakdown; click to show it in the word card.
private struct WordRow: View, @MainActor Equatable {
    let word: Segment
    let isSelected: Bool
    let isSaved: Bool
    let typeface: ReadingTypeface
    let select: () -> Void

    static func == (a: WordRow, b: WordRow) -> Bool {
        a.word == b.word && a.isSelected == b.isSelected && a.isSaved == b.isSaved && a.typeface == b.typeface
    }

    var body: some View {
        Button(action: select) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(word.text).font(ReadingFont.font(size: 19, typeface: typeface))
                    PinyinText(syllables: word.syllables).font(.system(size: 12, weight: .medium))
                }
                .frame(minWidth: 72, alignment: .leading)
                Text(word.gloss.isEmpty ? "—" : Gloss.clean(word.gloss))
                    .font(.callout)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if word.readingCorrected {
                        Image(systemName: "circle.dotted").foregroundStyle(Sheet.corrected).help("Context reading")
                    }
                    if let level = word.hskLevel {
                        Text(HSKTable.label(for: level)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if isSaved {
                        Image(systemName: "star.fill").foregroundStyle(Sheet.saved).help("In your Vocabulary")
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .help(word.definitions.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([word.text, word.pinyin, word.gloss, word.hskLevel.map { HSKTable.label(for: $0) } ?? "",
                             isSaved ? "in your Vocabulary" : ""].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
