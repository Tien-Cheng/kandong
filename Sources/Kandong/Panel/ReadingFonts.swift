import AppKit
import CoreText
import KandongKit

/// The fonts of one `ReadingStyle` and typeface, with their typeset lines kept: the same few hundred
/// syllables and characters come back in every text.
@MainActor
final class ReadingFonts {
    private struct Key: Hashable {
        let style: ReadingStyle
        let typeface: ReadingTypeface
    }

    private struct LineKey: Hashable {
        let text: String
        let face: ReadingFace
    }

    private static var all: [Key: ReadingFonts] = [:]

    static func of(_ style: ReadingStyle, _ typeface: ReadingTypeface) -> ReadingFonts {
        let key = Key(style: style, typeface: typeface)
        if let fonts = all[key] { return fonts }
        let fonts = ReadingFonts(style: style, typeface: typeface)
        all[key] = fonts
        return fonts
    }

    private let han: NSFont
    private let latin: NSFont
    private let pinyin: NSFont
    private var lines: [LineKey: (line: CTLine, width: CGFloat)] = [:]

    private init(style: ReadingStyle, typeface: ReadingTypeface) {
        han = ReadingFont.nsFont(size: style.hanSize, typeface: typeface)
        latin = .systemFont(ofSize: style.latinSize)
        pinyin = .systemFont(ofSize: style.pinyinSize, weight: .medium)
    }

    /// A typeset line; its colour is the context's fill colour.
    func line(_ text: String, _ face: ReadingFace) -> CTLine { typeset(text, face).line }

    private func typeset(_ text: String, _ face: ReadingFace) -> (line: CTLine, width: CGFloat) {
        let key = LineKey(text: text, face: face)
        if let found = lines[key] { return found }
        // Enough for several long texts; a long-lived panel shouldn't keep every word it ever showed.
        if lines.count > 8000 { lines.removeAll() }
        let line = make(text, face)
        let found = (line: line, width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        lines[key] = found
        return found
    }

    private func make(_ text: String, _ face: ReadingFace) -> CTLine {
        let font = switch face {
        case .han: han
        case .latin: latin
        case .pinyin: pinyin
        }
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
    }

    private func extent(_ face: ReadingFace) -> (ascent: CGFloat, descent: CGFloat) {
        switch face {
        // WenKai's own; PingFang's are looser, and the rows should be the same in both.
        case .han: (han.pointSize * 0.93, han.pointSize * 0.26)
        case .latin: (latin.ascender, -latin.descender)
        case .pinyin: (pinyin.ascender, -pinyin.descender)
        }
    }
}

extension ReadingFonts: @MainActor ReadingMeasuring {
    func width(of text: String, in face: ReadingFace) -> CGFloat { typeset(text, face).width }
    func ascent(of face: ReadingFace) -> CGFloat { extent(face).ascent }
    func descent(of face: ReadingFace) -> CGFloat { extent(face).descent }
}
