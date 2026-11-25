import Foundation
import Testing
@testable import KandongKit

private func word(_ text: String, _ pinyin: String, id: Int = 0) -> Segment {
    Segment(id: id, kind: .word, text: text, original: text, syllables: pinyin.split(separator: " ").map { Syllable(marked: String($0)) })
}

private func pass(_ text: String) -> Segment {
    Segment(id: 0, kind: .passThrough, text: text, original: text)
}

private func describe(_ units: [ReadingUnit]) -> [String] {
    units.map { unit in
        let mark = unit.staysWithPrevious ? "=" : unit.isAttached ? "-" : ""
        switch unit.kind {
        case .word(let segment): return mark + segment.text
        case .text(let text, .han): return mark + "[" + text + "]"
        case .text(let text, _): return mark + text
        case .lineBreak: return "⏎"
        }
    }
}

/// Every character is as wide as its size, so positions are easy to work out.
private struct FixedMeasure: ReadingMeasuring {
    var style = ReadingStyle.short
    func width(of text: String, in face: ReadingFace) -> CGFloat {
        switch face {
        case .han: CGFloat(text.count) * style.hanSize
        case .latin: CGFloat(text.count) * style.latinSize / 2
        case .pinyin: CGFloat(text.count) * style.pinyinSize / 2
        }
    }
    func ascent(of face: ReadingFace) -> CGFloat { face == .han ? 24 : face == .latin ? 23 : 11 }
    func descent(of face: ReadingFace) -> CGFloat { face == .han ? 7 : face == .latin ? 5 : 3 }
}

@Suite struct ReadingUnitTests {
    @Test func punctuationStaysWithItsWord() {
        #expect(describe(ReadingUnit.all(in: [word("好", "hǎo"), pass("。"), word("走", "zǒu"), pass(", ok")])) == ["好", "=[。]", "-走", "=,", "ok"])
    }

    @Test func splitsFullWidthMarksFromEnglish() {
        // The comma ends the Chinese line it belongs to; the English after it may start the next.
        #expect(describe(ReadingUnit.all(in: [word("好", "hǎo"), pass("，feature"), word("能", "néng")])) == ["好", "=[，]", "-feature", "能"])
        #expect(describe(ReadingUnit.all(in: [pass("beta（v2）"), word("版", "bǎn")])) == ["beta", "-[（]", "=v2", "=[）]", "-版"])
    }

    @Test func openingMarksKeepWhatFollows() {
        #expect(describe(ReadingUnit.all(in: [pass("@"), word("张三", "zhāng sān"), pass(" #"), word("话题", "huà tí")])) == ["@", "=张三", "#", "=话题"])
        #expect(describe(ReadingUnit.all(in: [word("说", "shuō"), pass("：“"), word("走", "zǒu"), pass("。”")])) == ["说", "=[：]", "-[“]", "=走", "=[。”]"])
    }

    @Test func sharedMarksFollowTheTextTheyTouch() {
        #expect(describe(ReadingUnit.all(in: [word("他", "tā"), pass("“"), word("走", "zǒu"), pass("”…")])) == ["他", "-[“]", "=走", "=[”…]"])
        #expect(describe(ReadingUnit.all(in: [pass("say “hi” now")])) == ["say", "“hi”", "now"])
    }

    @Test func keepsLineBreaksAndDropsIndents() {
        #expect(describe(ReadingUnit.all(in: [word("一", "yī"), pass("。\n\n　　"), word("二", "èr")])) == ["一", "=[。]", "⏎", "⏎", "二"])
        #expect(describe(ReadingUnit.all(in: [word("一", "yī"), pass(" one two\nthree")])) == ["一", "one", "two", "⏎", "three"])
    }
}

@Suite struct ReadingLayoutTests {
    private func layout(_ segments: [Segment], width: CGFloat = 400, style: ReadingStyle = .short, showsPinyin: Bool = true) -> ReadingLayout {
        ReadingLayout(units: ReadingUnit.all(in: segments), width: width, style: style, measure: FixedMeasure(style: style), showsPinyin: { _ in showsPinyin })
    }

    @Test func chineseAndEnglishShareABaseline() {
        let layout = layout([word("这个", "zhè ge"), pass(" feature，"), word("好", "hǎo")])
        #expect(layout.rows.count == 1)
        let baselines = Set(layout.items.flatMap(\.runs).filter { $0.face != .pinyin }.map(\.origin.y))
        #expect(baselines == [layout.rows[0].baseline])
        #expect(ReadingStyle.short.latinSize == 25)
        #expect(ReadingStyle.passage.latinSize == 21)
    }

    @Test func pinyinIsCentredOverItsCharacter() throws {
        let runs = layout([word("好", "hǎo")]).items[0].runs
        let pinyin = try #require(runs.first { $0.face == .pinyin }), han = try #require(runs.first { $0.face == .han })
        #expect(pinyin.origin.x + pinyin.width / 2 == han.origin.x + han.width / 2)
        #expect(pinyin.origin.y < han.origin.y)
        #expect(pinyin.tone == 3)
    }

    @Test func onlyALongSyllableWidensItsCell() {
        let short = layout([word("好", "hǎo")]).items[0].frame.width
        #expect(short == ReadingStyle.short.hanSize * 1.2 + 4)
        let long = layout([word("壮", "zhuàng")]).items[0]
        #expect(long.frame.width == long.runs[0].width + 3 + 4, "\(long)")
        #expect(long.frame.width == 43, "\(long)")
        #expect(layout([word("壮", "zhuàng")], showsPinyin: false).items[0].frame.width == short)
    }

    @Test func closingPunctuationNeverStartsALineOrOverflows() {
        let cell = ReadingStyle.short.hanSize * 1.2 + 4
        // Two words fit, but not with a mark after the second: the word moves down with it.
        let width = cell * 2 + 6 + 4
        let layout = layout([word("一", "yī"), word("二", "èr"), pass("！？"), word("三", "sān")], width: width)
        #expect(layout.rows.map { layout.items[$0.items].map { $0.runs.last!.text } } == [["一"], ["二", "！？"], ["三"]])
        for item in layout.items { #expect(item.frame.maxX <= width + ReadingStyle.short.hanSize / 2) }
    }

    @Test func theEmptyHalfOfAMarkHangsPastTheMargin() {
        let cell = ReadingStyle.short.hanSize * 1.2 + 4
        let layout = layout([word("一", "yī"), pass("。")], width: cell + ReadingStyle.short.hanSize / 2)
        #expect(layout.rows.count == 1)
    }

    @Test func breaksATokenLongerThanTheLine() {
        let url = "https://example.com/" + String(repeating: "a", count: 80)
        let layout = layout([word("看", "kàn"), pass(" " + url)], width: 300)
        #expect(layout.items.allSatisfy { $0.frame.maxX <= 300 })
        #expect(layout.items.dropFirst().flatMap(\.runs).map(\.text).joined() == url)
    }

    @Test func rowsWithoutWordsHaveNoRoomForPinyin() {
        let layout = layout([pass("English only\n"), word("好", "hǎo")])
        #expect(layout.rows.count == 2)
        #expect(layout.rows[0].frame.height < layout.rows[1].frame.height)
        #expect(layout.size.height == layout.rows[1].frame.maxY)
    }

    @Test func findsTheWordUnderThePointer() {
        let layout = layout([word("一", "yī", id: 0), pass(" and "), word("二", "èr", id: 2)])
        let second = layout.items[2].frame
        #expect(layout.word(at: CGPoint(x: second.midX, y: second.midY)) == 2)
        #expect(layout.word(at: CGPoint(x: layout.items[1].frame.midX, y: second.midY)) == nil)
        #expect(layout.word(at: CGPoint(x: 5, y: 900)) == nil)
    }

    @Test func emptyTextHasNoHeight() {
        #expect(layout([]).size.height == 0)
    }
}
