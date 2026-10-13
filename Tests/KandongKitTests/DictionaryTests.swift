import Testing
@testable import KandongKit

@Suite struct PinyinTests {
    @Test func marksTones() {
        #expect(Pinyin.display(Pinyin.syllables(numbered: "ni3 hao3")) == "nǐ hǎo")
        #expect(Pinyin.syllable(numbered: "lu:e4").text == "lüè")
        #expect(Pinyin.syllable(numbered: "gou1").text == "gōu")
        #expect(Pinyin.syllable(numbered: "liu4").text == "liù")
        #expect(Pinyin.syllable(numbered: "gui4").text == "guì")
        #expect(Pinyin.syllable(numbered: "le5") == Syllable(text: "le", tone: 5))
        #expect(Pinyin.syllable(numbered: "Bei3").text == "Běi")
    }

    @Test func readsTones() {
        #expect(Pinyin.tone(ofMarked: "hǎo") == 3)
        #expect(Pinyin.tone(ofMarked: "lǜ") == 4)
        #expect(Pinyin.tone(ofMarked: "de") == 5)
        #expect(Pinyin.folded("Lǜ shī") == "lushi")
    }

    @Test func parsesCedictLine() {
        let entry = CEDict.parse("傳統 传统 [chuan2 tong3] /tradition/traditional/")
        #expect(entry?.traditional == "傳統")
        #expect(entry?.simplified == "传统")
        #expect(entry?.definitions == ["tradition", "traditional"])
    }
}

@Suite(.enabled(if: TestData.hasDictionary, "run scripts/fetch-data.sh"), .timeLimit(.minutes(1)))
struct OfflineAnalyzerTests {
    let analyzer = TestData.analyzer!

    func words(_ text: String) -> [String] { analyzer.analyze(text).words.map(\.text) }
    func reading(_ text: String, _ word: String) -> String? {
        analyzer.analyze(text).words.first { $0.text == word }?.pinyin
    }

    @Test func segmentsMixedText() {
        let analysis = analyzer.analyze("OK明白了，所以这是一个发音问题？这个词的English是什么？@Xiao Ming 你跟老师沟通过了吗？")
        let words = analysis.words.map(\.text)
        #expect(words.contains("发音"))
        #expect(words.contains("问题"))
        #expect(words.contains("沟通"), "repairs 沟|通过 → 沟通|过")
        #expect(!words.contains("通过"))
        let passThrough = analysis.segments.filter { !$0.isWord }.map(\.text)
        #expect(passThrough.contains { $0.contains("English") })
        #expect(passThrough.contains { $0.contains("@Xiao Ming") })
        #expect(analysis.simplifiedText == analysis.source)
    }

    @Test func picksContextualReadings() {
        #expect(reading("他跑得很快", "得") == "de")
        #expect(reading("我得走了", "得") == "děi")
        #expect(reading("这个很行", "行") == "xíng")
        #expect(reading("我已经吃了", "了") == "le")
        #expect(reading("我了解", "了解") == "liǎo jiě")
        #expect(reading("这个", "这个") == "zhè ge")
    }

    @Test func keepsTraditionalOriginal() {
        let analysis = analyzer.analyze("這個問題我已經懂了")
        #expect(analysis.containsTraditional)
        #expect(analysis.simplifiedText == "这个问题我已经懂了")
        let problem = analysis.words.first { $0.text == "问题" }
        #expect(problem?.original == "問題")
        #expect(problem?.pinyin == "wèn tí")
    }

    @Test func attachesGlossAndLevel() {
        let word = analyzer.analyze("沟通").words.first
        #expect(word?.hskLevel == 5)
        #expect(word?.gloss.contains("communicate") == true)
    }

    @Test func noChineseMeansNoWords() {
        #expect(!analyzer.analyze("good morning").hasChinese)
    }
}
