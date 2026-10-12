import Foundation

/// HSK 3.0 word levels (1–6, with 7 standing for the 7–9 band) and corpus frequency ranks.
public struct HSKTable: Sendable {
    public struct Info: Sendable, Hashable {
        public let level: Int
        public let frequencyRank: Int
    }

    private let words: [String: Info]

    public init(words: [String: Info] = [:]) {
        self.words = words
    }

    /// Reads `word<TAB>level<TAB>rank` lines as written by `scripts/fetch-data.sh`.
    public init(contentsOf url: URL) throws {
        var words: [String: Info] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t")
            guard fields.count >= 3, let level = Int(fields[1]), let rank = Int(fields[2]) else { continue }
            words[String(fields[0])] = Info(level: level, frequencyRank: rank)
        }
        self.init(words: words)
    }

    public func info(for word: String) -> Info? { words[word] }

    public func level(of word: String) -> Int? { words[word]?.level }

    /// Display label for a level: "HSK 3", or "HSK 7–9" for the advanced band.
    public static func label(for level: Int) -> String {
        level >= 7 ? "HSK 7–9" : "HSK \(level)"
    }
}
