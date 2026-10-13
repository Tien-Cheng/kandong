import Foundation
import Testing
@testable import KandongKit

@Suite struct ETOGlossaryTests {
    /// The glossary's CSV shape: a banner, a blank row, then the header.
    static let csv = """
    "This glossary is shared under a Creative Commons BY-NC 4.0 license.
    See https://eto.tech",,,,
    ,,,,
    Chinese term,English translation,Translator's notes,Pinyin,Last modified
    多摸,Multimodal,"Multimodality is the application of multiple literacies, within one medium.",duo1 mo2,5/4/2023
    多模态 (多模),Multimodal. Alternatives: Multiple modalities (abbreviated: Multimodal),,duo1 mo2 tai4 (abbreviated: duo1 mo2),1/2/2024
    绿色能源,Green energy,,lv4 se4 neng2 yuan2,1/2/2024
    的确,Indeed,,di2 que4,1/2/2024
    处,Error retrieving definition.,,chu4,1/2/2024
    3D打印,3D printing,,3D da3 yin4,1/2/2024
    多摸,Multimodal,,duo1 mo2,5/4/2023
    关系,Relationship / relation,,guan1 xi0,1/2/2024
    """

    @Test func convertsToCEDICTFormat() throws {
        let converted = ETOGlossary.convert(csv: Self.csv, date: Date(timeIntervalSince1970: 1_800_000_000))
        let lines = converted.text.split(separator: "\n").map(String.init)
        #expect(lines.contains("# name: \(ETOGlossary.name)"))
        #expect(lines.contains { $0.hasPrefix("# license: CC BY-NC 4.0") })
        let entries = lines.filter { !$0.hasPrefix("#") }
        #expect(entries == [
            "多摸 多摸 [duo1 mo2] /Multimodal/",
            "多模态 多模态 [duo1 mo2 tai4] /Multimodal/Multiple modalities/",
            "多模 多模 [duo1 mo2] /Multimodal/Multiple modalities/",
            "绿色能源 绿色能源 [lu:4 se4 neng2 yuan2] /Green energy/",
            "的确 的确 [di2 que4] /Indeed/",
            "关系 关系 [guan1 xi5] /Relationship or relation/",
        ], "broken rows, non-Chinese terms and duplicates are left out")
        #expect(converted.count == entries.count)
        // It reads back as an add-on.
        let addOn = AddOnDictionary(url: URL(fileURLWithPath: "/tmp/eto-technical-terms.u8"), text: converted.text)
        #expect(addOn.id == ETOGlossary.id && addOn.entryCount == 6 && addOn.updated == "2027-01-15")
        #expect(CEDict(text: "", addOns: [addOn]).entries(for: "绿色能源").first?.syllables.first?.text == "lǜ")
    }
}

@Suite(.enabled(if: TestData.hasDictionary, "run scripts/fetch-data.sh"))
struct AddOnDictionaryTests {
    static let addOn = AddOnDictionary(url: URL(fileURLWithPath: "/tmp/tech.u8"), text: """
    # name: Technical terms (test)
    多摸 多摸 [duo1 mo2] /Multimodal/
    多模态 多模态 [duo1 mo2 tai4] /Multimodal/
    大模型 大模型 [da4 mo2 xing2] /Large model/
    采样 采样 [cai3 yang4] /Sampling (signal processing)/
    """)

    static let analyzer: OfflineAnalyzer = {
        let data = TestData.repoRoot.appendingPathComponent("Data")
        let dict = try! CEDict(contentsOf: data.appendingPathComponent("cedict_ts.u8"), addOns: [addOn])
        return OfflineAnalyzer(dictionary: dict, hsk: try! HSKTable(contentsOf: data.appendingPathComponent("hsk.tsv")))
    }()

    @Test func addOnWordsAreReadAsOneWord() throws {
        #expect(TestData.analyzer!.analyze("多摸").words.count == 2, "without the add-on: 多 + 摸")
        let words = Self.analyzer.analyze("多摸").words
        #expect(words.map(\.text) == ["多摸"])
        #expect(words.first?.pinyin == "duō mó")
        #expect(words.first?.gloss == "Multimodal", "the add-on's meaning stands in for CC-CEDICT's")
        #expect(Self.analyzer.analyze("多模态大模型来了").words.map(\.text).prefix(2) == ["多模态", "大模型"])
    }

    @Test func cedictKeepsItsMeaningAndTheAddOnAddsOne() throws {
        let word = try #require(Self.analyzer.analyze("采样").words.first)
        #expect(!word.definitions.isEmpty, "CC-CEDICT's own sense stays first")
        #expect(word.addOnGlosses == [AddOnGloss(source: "Technical terms (test)", text: "Sampling (signal processing)")])
    }

    @Test func glossaryMeaningsReachThePrompt() throws {
        let analysis = Self.analyzer.analyze("多摸")
        let request = Prompts.learn(text: "多摸", analysis: analysis, context: "", terms: [])
        #expect(request.user.contains("多摸 → Multimodal"))
    }

    @Test func loadsEveryFileInTheFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("addons-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.addOn.text.write(to: folder.appendingPathComponent("tech.u8"), atomically: true, encoding: .utf8)
        try "ignored".write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let found = AddOnDictionary.all(in: folder)
        #expect(found.map(\.name) == ["Technical terms (test)"])
        #expect(found.first?.entryCount == 4)
        #expect(AddOnDictionary.all(in: folder.appendingPathComponent("missing")).isEmpty)
    }
}

/// Downloads the real glossary. Opt in: `KANDONG_LIVE=1 swift test --filter LiveETOGlossaryTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KANDONG_LIVE"] == "1" && TestData.hasDictionary))
struct LiveETOGlossaryTests {
    @Test func downloadsAndReadsTechnicalTerms() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("eto-\(UUID())")
        let addOn = try await ETOGlossary.download(into: folder)
        print("ETO glossary: \(addOn.entryCount) entries, \(addOn.text.utf8.count / 1024) KB")
        #expect(addOn.entryCount > 12_000)
        let data = TestData.repoRoot.appendingPathComponent("Data")
        let dict = try CEDict(contentsOf: data.appendingPathComponent("cedict_ts.u8"), addOns: AddOnDictionary.all(in: folder))
        let analyzer = OfflineAnalyzer(dictionary: dict, hsk: try HSKTable(contentsOf: data.appendingPathComponent("hsk.tsv")))
        for text in ["多摸", "多模态感知", "大模型", "这个多模态大模型支持图像输入"] {
            let words = analyzer.analyze(text).words
            print("\(text) → " + words.map { "\($0.text) [\($0.pinyin)] \($0.gloss)" }.joined(separator: " | "))
        }
        #expect(analyzer.analyze("多摸").words.first?.gloss == "Multimodal")
        // Ordinary text still splits as before.
        #expect(analyzer.analyze("我们今天去吃火锅").words.map(\.text) == TestData.analyzer!.analyze("我们今天去吃火锅").words.map(\.text))
    }
}
