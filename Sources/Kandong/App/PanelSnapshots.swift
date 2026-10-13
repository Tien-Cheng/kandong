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
            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("kandong-snapshot-\(UUID().uuidString)")
            let model = AppModel(previewSettings: settings, workspacePath: workspace.path)
            guard let engine = await model.readyEngine() else {
                print("dictionary not loaded")
                return
            }
            let controller = ResultPanelController(model: model)
            let session = LookupSession(source: scenario.source)
            session.backend = lmStudio
            session.backendLabel = "LM Studio · google/gemma-4-12b"
            session.backendIsLocal = true
            scenario.fill(session, engine)
            model.session = session
            controller.selectedWordID = scenario.selectWord.flatMap { word in session.analysis?.words.first { $0.text == word }?.id }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let dark = appearance == .darkAqua
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
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
                let url = folder.appendingPathComponent("\(scenario.name)-\(dark ? "dark" : "light").png")
                try? png.write(to: url)
                print(url.path)
            }
            try? FileManager.default.removeItem(at: workspace)
        }
    }

    private struct Scenario {
        let name: String
        var source: LookupSource = .selection
        var myLevel = 0
        var selectWord: String?
        var height: CGFloat = 640
        let fill: @MainActor (LookupSession, LookupEngine) -> Void
    }

    private static let scenarios: [Scenario] = [
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
