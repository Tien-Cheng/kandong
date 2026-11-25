import Foundation

/// The sizes the Reading is set in.
public struct ReadingStyle: Hashable, Sendable {
    public var hanSize: CGFloat
    public var pinyinSize: CGFloat
    /// Between words.
    public var wordGap: CGFloat
    public var rowGap: CGFloat

    /// English capitals stand about as tall beside the Chinese as in PingFang's own Latin.
    public var latinSize: CGFloat { (hanSize * 0.96).rounded() }
    /// Even cells keep the characters' rhythm; only a long syllable (zhuàng) widens its own.
    var minCellWidth: CGFloat { hanSize * 1.2 }
    /// A hair of space between neighbouring syllables' pinyin.
    let cellPadding: CGFloat = 1.5
    /// Room around a word for its selection box.
    let wordInset: CGFloat = 2
    let pinyinGap: CGFloat = 2

    /// A sentence or two: the Chinese is set large, it's what the user is here to read.
    public static let short = ReadingStyle(hanSize: 26, pinyinSize: 12, wordGap: 6, rowGap: 10)
    /// Long text in passages.
    public static let passage = ReadingStyle(hanSize: 22, pinyinSize: 11, wordGap: 5, rowGap: 6)
}

/// Measures text in the faces the Reading is drawn with.
public protocol ReadingMeasuring {
    func width(of text: String, in face: ReadingFace) -> CGFloat
    func ascent(of face: ReadingFace) -> CGFloat
    func descent(of face: ReadingFace) -> CGFloat
}

/// Where everything in the Reading goes, in a top-left coordinate space: pinyin above each
/// character, and Chinese and English on one baseline per row.
public struct ReadingLayout: Equatable, Sendable {
    /// Text drawn in one go.
    public struct Run: Equatable, Sendable {
        public var text: String
        public var face: ReadingFace
        /// The left end of its baseline.
        public var origin: CGPoint
        public var width: CGFloat
        /// The tone, for pinyin.
        public var tone: Int?
    }

    /// One word, or one run of pass-through text.
    public struct Item: Equatable, Sendable {
        /// Nil for pass-through text.
        public var segment: Segment?
        public var frame: CGRect
        public var runs: [Run]
    }

    public struct Row: Equatable, Sendable {
        public var frame: CGRect
        public var baseline: CGFloat
        /// The row's items, as indices into `items`.
        public var items: Range<Int>
    }

    public private(set) var items: [Item] = []
    public private(set) var rows: [Row] = []
    public private(set) var size = CGSize.zero

    /// The word at `point`, as an index into `items`.
    public func word(at point: CGPoint) -> Int? {
        guard let row = rows.first(where: { $0.frame.minY <= point.y && point.y < $0.frame.maxY }) else { return nil }
        return row.items.first { items[$0].segment != nil && items[$0].frame.contains(point) }
    }

    /// The items to draw for `rect`.
    public func items(in rect: CGRect) -> [Item] {
        rows.filter { $0.frame.insetBy(dx: 0, dy: -4).intersects(rect) }.flatMap { items[$0.items] }
    }

    public init(
        units: [ReadingUnit], width: CGFloat, style: ReadingStyle, measure: some ReadingMeasuring,
        showTraditional: Bool = false, showsPinyin: (Segment) -> Bool = { _ in true }
    ) {
        var builder = Builder(width: max(width, style.hanSize * 2), style: style, measure: measure)
        var cluster: [(unit: ReadingUnit, box: Box)] = []
        func place(_ builder: inout Builder<some ReadingMeasuring>) {
            builder.place(cluster)
            cluster = []
        }
        for unit in units {
            if case .lineBreak = unit.kind {
                place(&builder)
                builder.breakLine()
                continue
            }
            if !unit.staysWithPrevious { place(&builder) }
            cluster.append((unit, builder.box(for: unit, showTraditional: showTraditional, showsPinyin: showsPinyin)))
        }
        place(&builder)
        builder.finish()
        items = builder.items
        rows = builder.rows
        size = CGSize(width: width, height: rows.last?.frame.maxY ?? 0)
    }

    /// A unit measured but not yet placed; runs are relative to its left edge and the row's baseline.
    struct Box {
        var segment: Segment?
        var width: CGFloat
        var runs: [Run]
        /// Space at its right end that may hang past the margin: the empty half of a full-width mark.
        var hang: CGFloat = 0
    }

    private struct Builder<Measure: ReadingMeasuring> {
        let width: CGFloat
        let style: ReadingStyle
        let measure: Measure
        var items: [Item] = []
        var rows: [Row] = []
        private var rowStart = 0
        private var x: CGFloat = 0
        private var y: CGFloat = 0

        init(width: CGFloat, style: ReadingStyle, measure: Measure) {
            self.width = width
            self.style = style
            self.measure = measure
        }

        // MARK: Measuring

        func box(for unit: ReadingUnit, showTraditional: Bool, showsPinyin: (Segment) -> Bool) -> Box {
            switch unit.kind {
            case .lineBreak:
                return Box(width: 0, runs: [])
            case .text(let text, let face):
                let textWidth = measure.width(of: text, in: face)
                let hangs = face == .han && text.last.map { "，。、！？；：".contains($0) } == true
                return Box(width: textWidth, runs: [Run(text: text, face: face, origin: .zero, width: textWidth)],
                           hang: hangs ? style.hanSize * 0.5 : 0)
            case .word(let segment):
                let text = showTraditional ? segment.original : segment.text
                let characters = text.map(String.init)
                var runs: [Run] = []
                var left = style.wordInset
                func cell(_ text: String, _ pinyin: String, tone: Int, minWidth: CGFloat) {
                    let shown = showsPinyin(segment) ? pinyin : ""
                    let textWidth = measure.width(of: text, in: .han)
                    let pinyinWidth = shown.isEmpty ? 0 : measure.width(of: shown, in: .pinyin)
                    let cellWidth = max(minWidth, max(textWidth, pinyinWidth) + style.cellPadding * 2)
                    if !shown.isEmpty {
                        runs.append(Run(text: shown, face: .pinyin, origin: CGPoint(x: left + (cellWidth - pinyinWidth) / 2, y: pinyinBaseline),
                                        width: pinyinWidth, tone: tone))
                    }
                    runs.append(Run(text: text, face: .han, origin: CGPoint(x: left + (cellWidth - textWidth) / 2, y: 0), width: textWidth))
                    left += cellWidth
                }
                if segment.isAligned && characters.count == segment.syllables.count {
                    for (character, syllable) in zip(characters, segment.syllables) {
                        cell(character, syllable.text, tone: syllable.tone, minWidth: style.minCellWidth)
                    }
                } else {
                    cell(text, segment.pinyin, tone: segment.syllables.first?.tone ?? 5, minWidth: 0)
                }
                return Box(segment: segment, width: left + style.wordInset, runs: runs)
            }
        }

        /// The pinyin's baseline, from the row's.
        private var pinyinBaseline: CGFloat {
            -(measure.ascent(of: .han) + style.pinyinGap + measure.descent(of: .pinyin))
        }

        // MARK: Placing

        private func gap(before unit: ReadingUnit) -> CGFloat {
            rowStart == items.count || unit.isAttached ? 0 : style.wordGap
        }

        /// Places units that stay together, on the next line if this one hasn't room for all of them.
        mutating func place(_ cluster: [(unit: ReadingUnit, box: Box)]) {
            guard let first = cluster.first, let last = cluster.last else { return }
            let inner = cluster.dropFirst().reduce(0) { $0 + $1.box.width + ($1.unit.isAttached ? 0 : style.wordGap) }
            let total = first.box.width + inner - last.box.hang
            if x + gap(before: first.unit) + total > width, rowStart < items.count { breakLine() }
            let fits = total <= width
            for (unit, box) in cluster {
                let needed = gap(before: unit) + box.width - box.hang
                if !fits, x + needed > width, rowStart < items.count { breakLine() }
                if box.width - box.hang > width, case .text(let text, let face) = unit.kind {
                    placeBroken(text, face)
                } else {
                    add(box, gap: gap(before: unit))
                }
            }
        }

        /// A URL (say) longer than the line, broken wherever the line ends.
        private mutating func placeBroken(_ text: String, _ face: ReadingFace) {
            var piece = ""
            func pieceBox() -> Box {
                let width = measure.width(of: piece, in: face)
                return Box(width: width, runs: [Run(text: piece, face: face, origin: .zero, width: width)])
            }
            for character in text {
                if !piece.isEmpty, measure.width(of: piece + String(character), in: face) > width {
                    add(pieceBox(), gap: 0)
                    breakLine()
                    piece = ""
                }
                piece.append(character)
            }
            if !piece.isEmpty { add(pieceBox(), gap: 0) }
        }

        private mutating func add(_ box: Box, gap: CGFloat) {
            x += gap
            items.append(Item(segment: box.segment, frame: CGRect(x: x, y: 0, width: box.width, height: 0), runs: box.runs))
            x += box.width
        }

        /// Ends the row, moving its items from the baseline's space into the layout's.
        mutating func breakLine() {
            defer { rowStart = items.count; x = 0 }
            guard rowStart < items.count else { return }
            let range = rowStart..<items.count
            // Rows with no Chinese words don't keep room for pinyin.
            let hasWords = items[range].contains { $0.segment != nil }
            let pinyin = hasWords ? measure.ascent(of: .pinyin) + measure.descent(of: .pinyin) + style.pinyinGap : 0
            let ascent = max(measure.ascent(of: .han), measure.ascent(of: .latin))
            let descent = max(measure.descent(of: .han), measure.descent(of: .latin))
            let top = rows.isEmpty ? 0 : y + style.rowGap
            let baseline = (top + style.wordInset + pinyin + ascent).rounded()
            let bottom = baseline + descent + style.wordInset
            for index in range {
                items[index].frame.origin.y = top
                items[index].frame.size.height = bottom - top
                for run in items[index].runs.indices {
                    items[index].runs[run].origin.x += items[index].frame.minX
                    items[index].runs[run].origin.y += baseline
                }
            }
            rows.append(Row(frame: CGRect(x: 0, y: top, width: width, height: bottom - top), baseline: baseline, items: range))
            y = bottom
        }

        mutating func finish() { breakLine() }
    }
}
