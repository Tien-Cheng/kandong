#if DEBUG
import AppKit
import SwiftUI
import KandongKit

/// `Kandong --render-panel <folder>` (debug builds only): renders the Result panel for a few typical
/// Lookups, light and dark, to PNGs, without showing a window, registering shortcuts or touching the
/// user's settings, Workspace or History. The glass is drawn as a stand-in over a busy backdrop;
/// real Liquid Glass only renders in a window.
@MainActor
enum PanelSnapshots {
    static func render(to folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lmStudio = BackendConfig.openAI(.lmStudio, id: "lmstudio", name: "LM Studio")
        for scenario in scenarios {
            var settings = AppSettings()
            settings.backends = [.appleIntelligence, .chatGPT, lmStudio]
            settings.myLevel = scenario.myLevel
            settings.hasChosenLevel = scenario.myLevel != 0
            settings.readingTypeface = scenario.typeface
            settings.hasAnsweredOpenAtLogin = !scenario.asksOpenAtLogin
            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("kandong-snapshot-\(UUID().uuidString)")
            let loginItem = LoginItem(preview: .off, errorMessage: scenario.loginItemError)
            let model = AppModel(previewSettings: settings, workspacePath: workspace.path, loginItem: loginItem)
            guard let engine = await model.readyEngine() else {
                print("dictionary not loaded")
                return
            }
            let controller = ResultPanelController(model: model)
            let session = LookupSession(source: scenario.source)
            session.backend = lmStudio
            session.backendLabel = "LM Studio · google/gemma-4-12b"
            session.backendIsLocal = true
            session.mayAskOpenAtLogin = !settings.asksAboutLevel
            scenario.fill(session, engine)
            model.session = session
            controller.selectedWordID = scenario.selectWord.flatMap { word in session.analysis?.words.first { $0.text == word }?.id }
            for (suffix, appearance) in scenario.appearances {
                let dark = suffix.hasPrefix("dark")
                let view = ResultView(model: model, controller: controller)
                    .frame(width: 480, height: scenario.height)
                    .background { GlassStandIn(dark: dark) }
                    .clipShape(RoundedRectangle(cornerRadius: ResultPanelController.cornerRadius))
                    .padding(24)
                    .background(Backdrop())
                    .environment(\.colorScheme, dark ? .dark : .light)
                // Drawn by AppKit (not ImageRenderer), so scroll views and native controls render.
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: appearance)
                host.frame = NSRect(x: 0, y: 0, width: 528, height: scenario.height + 48)
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(300))
                host.layoutSubtreeIfNeeded()
                if scenario.scroll > 0, let scrollView = scrollView(in: host) {
                    scrollView.contentView.scroll(to: NSPoint(x: 0, y: scenario.scroll))
                    try? await Task.sleep(for: .milliseconds(200))
                    host.layoutSubtreeIfNeeded()
                }
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
                let url = folder.appendingPathComponent("\(scenario.name)-\(suffix).png")
                try? png.write(to: url)
                print(url.path)
            }
            try? FileManager.default.removeItem(at: workspace)
        }
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    private struct Scenario {
        let name: String
        var source: LookupSource = .selection
        var myLevel = 0
        var selectWord: String?
        var asksOpenAtLogin = false
        var loginItemError: String?
        var height: CGFloat = 640
        /// Points scrolled down.
        var scroll: CGFloat = 0
        var typeface = ReadingTypeface.kai
        var appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        let fill: @MainActor (LookupSession, LookupEngine) -> Void
    }

    private static func openAtLogin(_ session: LookupSession, _ engine: LookupEngine) {
        session.sourceText = "我们下周再讨论这个问题吧。"
        session.analysis = engine.offline(session.sourceText)
        session.translation = "Let's discuss this issue again next week."
        session.status = .done
    }

    private static let article = [
        ("新能源汽车今年的销量又创下了新的纪录。根据行业协会上周公布的数据，前十个月国内一共卖出了1280万辆，比去年同期增长了32%，其中纯电动车占了六成以上。",
         "New-energy vehicle sales have set another record this year. According to figures the industry association released last week, 12.8 million were sold in China in the first ten months, up 32% on the same period last year, and more than 60% of them were fully electric."),
        ("不过，价格战也让很多企业的日子越来越难过。BYD 在三月份率先降价，其他品牌只好跟着降，有些车型一个季度就便宜了4万块钱，利润几乎被压缩到了零。",
         "But the price war is making life harder and harder for many companies. BYD was the first to cut prices in March, and the other brands had no choice but to follow. Some models got 40,000 yuan cheaper in a single quarter, squeezing profits to almost nothing."),
        ("@老王 你上次说想换车，现在可能是个不错的 timing。我昨天去 Tesla 的店里 test drive 了一下，感觉还行，就是内饰太简单了。",
         "@老王 You said you wanted to change cars, and now might be good timing. I went for a test drive at the Tesla store yesterday. It felt all right, but the interior is too plain."),
        ("充电仍然是最大的问题。国庆节那几天，高速公路服务区里排队的车一眼望不到头，有人等了整整5个小时才充上电，最后干脆在车里睡了一觉。",
         "Charging is still the biggest problem. Over the National Day holiday the queues at motorway services stretched out of sight. Some people waited five whole hours to charge and ended up just sleeping in their cars."),
    ]

    private static func readArticle(_ session: LookupSession, _ engine: LookupEngine, translated: Int = 4, current: Int? = nil) {
        session.sourceText = article.map(\.0).joined(separator: "\n\n")
        let analysis = engine.offline(session.sourceText)
        session.split(into: analysis.passages.map(\.passage))
        session.analysis = analysis
        for (index, state) in session.passages.enumerated() where index < translated {
            state.translation = article[index].1
            state.status = .done
        }
        if let current {
            session.passages[current].translation = String(article[current].1.prefix(60))
            session.passages[current].status = .translating
        }
        session.translation = session.joinedTranslation
        session.status = current == nil ? .done : .translating
    }

    private static let scenarios: [Scenario] = [
        Scenario(name: "long", myLevel: 3, height: 760) { session, engine in readArticle(session, engine) },
        Scenario(name: "long-translating", myLevel: 3, selectWord: nil, height: 760) { session, engine in
            readArticle(session, engine, translated: 1, current: 1)
            session.translation = nil
        },
        Scenario(name: "long-word", myLevel: 3, selectWord: "内饰", height: 760) { session, engine in readArticle(session, engine) },
        Scenario(name: "long-end", myLevel: 3, height: 760, scroll: 1500) { session, engine in readArticle(session, engine) },
        Scenario(name: "long-explained", myLevel: 3, height: 760) { session, engine in
            readArticle(session, engine)
            session.passages[0].explanation = """
            - **Structure**: 根据…的数据 gives the source first, then **比去年同期增长了** compares with the same period last year.
            - **Words**: 创下…纪录 (chuàngxià … jìlù), "to set a record"; 占 (zhàn) here means "to make up" a share: 占了六成.
            - **Register**: neutral, news-like.
            """
        },
        Scenario(name: "long-failed", myLevel: 3, height: 760, scroll: 1300) { session, engine in
            readArticle(session, engine, translated: 2)
            for state in session.passages.dropFirst(2) { state.status = .missing }
            session.status = .failed("LM Studio isn't reachable at http://localhost:1234/v1. Is the server running?")
        },
        Scenario(name: "long-pingfang", myLevel: 3, height: 760, typeface: .system,
                 appearances: [("light-contrast", .accessibilityHighContrastAqua), ("dark-contrast", .accessibilityHighContrastDarkAqua)]) { session, engine in
            readArticle(session, engine)
        },
        Scenario(name: "long-reverse", myLevel: 3, height: 760) { session, engine in
            let english = [
                "I had a look at the numbers you sent over last night, and I think we should talk before the meeting on Thursday. The costs for the second quarter don't add up, and I'm worried that the client will notice before we have a good answer for them.",
                "Could you ask @Lily to bring the latest version of the spreadsheet? The one in the shared folder is at least two weeks old, and nobody seems to know who changed the totals on the third page, so it would help to have her walk us through it.",
            ]
            let chinese = ["我看了一下你昨晚发来的数据，我觉得我们应该在周四开会之前先聊聊。第二季度的成本对不上，我担心客户会在我们想好怎么回答之前就发现。",
                           "你能让 @Lily 把最新版的表格带来吗？共享文件夹里的那份至少是两周前的了，而且好像没人知道是谁改了第三页的总数，所以最好让她给我们讲一遍。"]
            session.direction = .reverse
            session.sourceText = english.joined(separator: "\n\n")
            session.split(into: Passage.split(session.sourceText))
            let passages = zip(session.passages, chinese).map { Passage(id: $0.id, text: $1, leading: $0.passage.leading) }
            session.analysis = engine.analyzer.analyze(passages, source: chinese.joined(separator: "\n\n"))
            for (state, text) in zip(session.passages, chinese) { state.translation = text; state.status = .done }
            session.translation = session.joinedTranslation
            session.note = "Neutral and polite; works with colleagues."
            session.status = .done
        },
        Scenario(name: "explained", myLevel: 3, height: 560) { session, engine in
            session.sourceText = "他还没还我钱。"
            session.analysis = engine.offline(session.sourceText)
            session.translation = "He still hasn't paid me back."
            session.status = .done
            session.explanation = "- **Grammar**: 还没 (hái méi) is \"still hasn't\"; the second **还** (huán) is \"to give back\".\n- **Words**: 还钱 (huán qián), to pay money back, e.g. 我明天还你钱。"
        },
        Scenario(name: "learn-polyphone", selectWord: "还", height: 760) { session, engine in
            let text = "他还没还我钱，这一行的人都知道银行不会借给他。"
            session.sourceText = text
            var analysis = engine.offline(text)
            let choices = ReadingChoice.all(in: analysis).filter { $0.word == "还" }
            if let first = choices.first, let second = choices.last {
                analysis = engine.applyReadings([first.key: "hái", second.key: "huán"], to: analysis)
            }
            session.analysis = analysis
            session.translation = "He still hasn't paid me back. Everyone in this line of work knows the bank won't lend to him."
            session.status = .done
        },
        Scenario(name: "learn-mixed", source: .otherApp, myLevel: 3, height: 620) { session, engine in
            let text = "这个 feature 明天能 ship 吗？多模态大模型的推理成本下降了一个数量级。@张三 你怎么看？ https://example.com"
            session.sourceText = text
            session.analysis = engine.offline(text)
            session.translation = "Can this feature ship tomorrow? The inference cost of multimodal large models has dropped by an order of magnitude. @张三 what do you think? https://example.com"
            session.status = .done
        },
        Scenario(name: "open-at-login", myLevel: 2, asksOpenAtLogin: true, height: 480, fill: openAtLogin),
        Scenario(name: "open-at-login-failed", myLevel: 2, asksOpenAtLogin: true,
                 loginItemError: "The operation couldn’t be completed. Operation not permitted", height: 500, fill: openAtLogin),
        // The question about My level comes first, alone.
        Scenario(name: "level-before-open-at-login", asksOpenAtLogin: true, height: 480, fill: openAtLogin),
        Scenario(name: "reverse", height: 520) { session, engine in
            session.direction = .reverse
            session.sourceText = "I can't make it tonight, something came up at work."
            let chinese = "我今晚去不了，工作上有点突发状况。"
            session.analysis = engine.offline(chinese)
            session.translation = chinese
            session.note = "Neutral and polite; works with friends and colleagues."
            session.status = .done
        },
        Scenario(name: "failed", source: .clipboard, myLevel: 2, height: 520) { session, engine in
            let text = "我们下周再讨论这个问题吧。"
            session.sourceText = text
            session.analysis = engine.offline(text)
            session.status = .failed("LM Studio isn't running. Start its server, then try again.")
        },
        Scenario(name: "translating", source: .screenCapture, myLevel: 2, height: 420) { session, engine in
            let text = "虽然天气不好，但是我们还是决定去爬山。"
            session.sourceText = text
            session.analysis = engine.offline(text)
            session.status = .translating
        },
    ]
}

/// Stands in for the panel's Liquid Glass in snapshots.
private struct GlassStandIn: View {
    let dark: Bool

    var body: some View {
        ZStack {
            Backdrop().blur(radius: 24)
            (dark ? Color.black.opacity(0.55) : Color.white.opacity(0.62))
        }
    }
}

/// A busy page behind the panel, like the article the user is reading.
private struct Backdrop: View {
    var body: some View {
        LinearGradient(colors: [.orange, .pink, .blue, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<40, id: \.self) { _ in
                        Text("文字 text 新闻 headline 阅读 reading 学习 learning").font(.system(size: 18)).foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .clipped()
    }
}
#endif
