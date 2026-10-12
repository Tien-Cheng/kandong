import Foundation
@testable import KandongKit

enum TestData {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let analyzer: OfflineAnalyzer? = {
        let data = repoRoot.appendingPathComponent("Data")
        guard let dict = try? CEDict(contentsOf: data.appendingPathComponent("cedict_ts.u8")),
              let hsk = try? HSKTable(contentsOf: data.appendingPathComponent("hsk.tsv"))
        else { return nil }
        return OfflineAnalyzer(dictionary: dict, hsk: hsk)
    }()

    static var hasDictionary: Bool { analyzer != nil }
}
