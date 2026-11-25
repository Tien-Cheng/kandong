import SwiftUI
import KandongKit

/// Renders the Explanation's Markdown: headings, bullets and inline styling. Its Chinese is set a
/// little larger than the English around it, in the user's Chinese typeface, so strokes stay clear.
struct MarkdownText: View {
    let markdown: String
    var typeface: ReadingTypeface = .kai

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(MarkdownLines.parse(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .blank:
                    Color.clear.frame(height: 2)
                case .heading(let text):
                    inline(text, strong: true).font(.headline)
                case .bullet(let level, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        inline(text)
                    }
                    .padding(.leading, CGFloat(level) * 12)
                case .paragraph(let text):
                    inline(text)
                }
            }
        }
        .textSelection(.enabled)
    }

    private static let hanSize: CGFloat = 15

    private func inline(_ text: String, strong: Bool = false) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        var start = attributed.startIndex
        while let first = attributed.characters[start...].firstIndex(where: \.isHan) {
            let end = attributed.characters[first...].firstIndex { !$0.isHan } ?? attributed.endIndex
            for (intent, range) in attributed[first..<end].runs[\.inlinePresentationIntent] {
                // The bundled WenKai has one weight, so emphasis falls to the system face.
                let isStrong = strong || intent?.contains(.stronglyEmphasized) == true
                attributed[range].font = isStrong ? .system(size: Self.hanSize, weight: .semibold) : ReadingFont.font(size: Self.hanSize, typeface: typeface)
            }
            start = end
        }
        return Text(attributed)
    }
}
