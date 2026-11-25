#if DEBUG
import AppKit
import SwiftUI
import KandongKit

/// `Kandong --time-panel` (debug builds only): times the Result panel's content for texts of a few
/// lengths, offscreen: analysing the text, opening, stepping through words, a Translation streaming
/// in, and scrolling. Nothing is shown and nothing of the user's is touched.
@MainActor
enum PanelTimings {
    private static let paragraph = "今天早上我跟朋友去公园散步，天气特别好，很多人在湖边跑步。我们一边走一边聊最近的工作，他说公司正在做一个新的 feature，下个月就要上线了，所以每天都加班到很晚。后来我们找了一家咖啡馆坐下来，点了两杯拿铁，继续讨论周末去哪里旅行。他想去杭州看西湖，我更想去成都吃火锅，最后我们决定先查一查高铁票再说。\n\n"

    static func run() async {
        for length in [120, 1000, 5000] {
            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("kandong-timing-\(UUID().uuidString)")
            let model = AppModel(previewSettings: AppSettings(), workspacePath: workspace.path)
            defer { try? FileManager.default.removeItem(at: workspace) }
            guard let engine = await model.readyEngine() else {
                print("dictionary not loaded")
                return
            }
            let text = String(String(repeating: paragraph, count: length / paragraph.count + 1).prefix(length))
            let controller = ResultPanelController(model: model)
            let session = LookupSession(source: .selection)
            session.sourceText = text
            let analyse = time { session.analysis = engine.offline(text) }
            session.split(into: session.analysis?.passages.map(\.passage) ?? [])
            session.analysis = session.analysis
            session.status = .translating
            // The panel itself, never shown.
            let host = controller.offscreenContent(size: NSSize(width: 480, height: 640))
            settle(host)
            let open = time {
                model.session = session
                settle(host)
            }
            controller.selectWord(step: 1)
            settle(host)
            let arrows = (1...10).map { _ in time { controller.selectWord(step: 1); settle(host) } }
            if session.isLong { await checkScrolling(controller, session, host) }
            let jumps = session.isLong ? (1...10).map { _ in time { controller.selectPassage(step: 1); settle(host) } } : []
            controller.selectedWordID = nil
            settle(host)
            let streamed = (1...20).map { count in
                time {
                    let text = String(repeating: "a word or two ", count: count)
                    if let passage = session.passages.first {
                        passage.status = .translating
                        passage.translation = text
                    } else {
                        session.progress = LookupProgress(completedParts: 0, totalParts: 1, translation: text)
                    }
                    settle(host)
                }
            }
            var scrolls: [Double] = []
            if let scrollView = scrollView(in: host) {
                scrolls = (1...20).map { step in
                    time {
                        scrollView.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step) * 120))
                        scrollView.reflectScrolledClipView(scrollView.contentView)
                        settle(host)
                    }
                }
            }
            print("\(length) chars, ms: analyse \(ms(analyse))  open \(ms(open))  arrow \(range(arrows))  passage \(range(jumps))  streamed \(range(streamed))  scroll \(range(scrolls))")
        }
    }

    /// Steps far through the text, and checks every selected word can be seen and that the text in
    /// sight stays put when the passages above it are translated.
    private static func checkScrolling(_ controller: ResultPanelController, _ session: LookupSession, _ host: NSView) async {
        // Not a nested run loop: the scrolling waits on the main queue, which this runs on.
        func waitAndCheck() async -> Bool {
            for _ in 0..<12 {
                settle(host)
                try? await Task.sleep(for: .milliseconds(30))
            }
            guard let id = controller.selectedWordID else { return false }
            return controller.readingBlocks.allObjects.contains { $0.window != nil && $0.contains(word: id) && $0.shows(word: id) }
        }
        var seen = 0, steps = 0
        for _ in 0..<12 { controller.selectPassage(step: 1); steps += 1; seen += await waitAndCheck() ? 1 : 0 }
        for _ in 0..<30 { controller.selectWord(step: 1); steps += 1; seen += await waitAndCheck() ? 1 : 0 }
        for _ in 0..<6 { controller.selectPassage(step: -1); steps += 1; seen += await waitAndCheck() ? 1 : 0 }
        controller.selectedWordID = session.words.last?.id
        steps += 1
        seen += await waitAndCheck() ? 1 : 0
        print("  selected word in sight \(seen)/\(steps)")
        controller.selectedWordID = nil
        guard let scrollView = scrollView(in: host) else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 1500))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        _ = await waitAndCheck()
        guard let block = controller.readingBlocks.allObjects.filter({ $0.visibleTop != nil }).min(by: { $0.visibleTop! < $1.visibleTop! }),
              let passage = block.passage, let before = block.visibleTop else { return }
        let offset = before - scrollView.contentView.bounds.minY
        for state in session.passages.prefix(passage) { state.translation = String(repeating: "A line of the Translation. ", count: 8); state.status = .done }
        _ = await waitAndCheck()
        let after = block.visibleTop.map { $0 - scrollView.contentView.bounds.minY }
        print("  passage \(passage) in sight at \(ms(offset)), after \(passage) above it were translated: \(after.map(ms) ?? "gone")")
        for state in session.passages { state.translation = nil; state.status = .waiting }
        scrollView.contentView.scroll(to: .zero)
        _ = await waitAndCheck()
    }

    private static func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date())
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    private static func time(_ work: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        work()
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    private static func ms(_ value: CGFloat) -> String { String(format: "%.1f", value) }
    private static func range(_ values: [Double]) -> String {
        let sorted = values.sorted()
        return sorted.isEmpty ? "–" : "median \(ms(sorted[sorted.count / 2])) max \(ms(sorted.last!))"
    }
}
#endif
