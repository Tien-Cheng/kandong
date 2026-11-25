import SwiftUI
import KandongKit

/// One word of the breakdown; click to show it in the word card.
struct WordRow: View {
    let controller: ResultPanelController
    let word: Segment
    let isSaved: Bool
    let typeface: ReadingTypeface

    var body: some View {
        let isSelected = controller.selectedWordID == word.id
        Button {
            controller.selectedWordID = isSelected ? nil : word.id
        } label: {
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
