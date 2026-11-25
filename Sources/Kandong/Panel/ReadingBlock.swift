import AppKit
import SwiftUI
import KandongKit

/// What a `ReadingBlock` shows.
struct ReadingContent: Equatable {
    var segments: [Segment]
    var style: ReadingStyle
    var typeface: ReadingTypeface
    var showTraditional = false
    /// Words shown without pinyin, by Segment id.
    var withoutPinyin: Set<Int> = []
    /// Words in the Vocabulary.
    var saved: Set<String> = []
}

/// What can be done from a `ReadingBlock`.
@MainActor
protocol ReadingBlockActions: AnyObject {
    func select(_ segment: Segment)
    /// The menu for a word, or (nil) for the text around it.
    func menu(for segment: Segment?) -> [ReadingMenuItem]
    func register(_ view: ReadingBlockView)
}

enum ReadingMenuItem {
    case action(String, () -> Void)
    case separator
}

/// A text with pinyin above each character, coloured by tone. Drawn in one view: a view per word
/// costs about ten times as much, which long text can't afford.
struct ReadingBlock: NSViewRepresentable {
    let content: ReadingContent
    let selectedID: Int?
    let actions: ReadingBlockActions

    func makeNSView(context: Context) -> ReadingBlockView {
        let view = ReadingBlockView()
        actions.register(view)
        return view
    }

    func updateNSView(_ view: ReadingBlockView, context: Context) {
        view.actions = actions
        view.content = content
        view.selectedID = selectedID
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReadingBlockView, context: Context) -> CGSize? {
        let width = min(proposal.width ?? 440, 10_000)
        return CGSize(width: width, height: nsView.layout(width: width, content: content).size.height)
    }
}

final class ReadingBlockView: NSView, NSViewToolTipOwner {
    weak var actions: ReadingBlockActions?

    var content = ReadingContent(segments: [], style: .short, typeface: .kai) {
        didSet {
            guard content != oldValue else { return }
            contentChanged()
        }
    }

    var selectedID: Int? {
        didSet {
            guard selectedID != oldValue else { return }
            for id in [oldValue, selectedID] {
                if let frame = id.flatMap(frame(ofWord:)) { setNeedsDisplay(frame.insetBy(dx: -2, dy: -3)) }
            }
            elements = nil
        }
    }

    private var layouts: [CGFloat: ReadingLayout] = [:]
    private var layoutContent: ReadingContent?
    private var toolTipWidth: CGFloat?
    private var elements: [NSAccessibilityElement]?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Layout

    private var current: ReadingLayout { layout(width: bounds.width, content: content) }

    /// The layout for a width; the last few are kept, since SwiftUI asks about several.
    func layout(width: CGFloat, content: ReadingContent) -> ReadingLayout {
        if layoutContent != content {
            layouts = [:]
            layoutContent = content
        }
        if let found = layouts[width] { return found }
        if layouts.count > 8 { layouts = [:] }
        let layout = ReadingLayout(
            units: ReadingUnit.all(in: content.segments), width: width, style: content.style,
            measure: ReadingFonts.of(content.style, content.typeface), showTraditional: content.showTraditional,
            showsPinyin: { !content.withoutPinyin.contains($0.id) }
        )
        layouts[width] = layout
        return layout
    }

    func frame(ofWord id: Int) -> CGRect? {
        guard bounds.width > 0 else { return nil }
        return current.items.first { $0.segment?.id == id }?.frame
    }

    func contains(word id: Int) -> Bool {
        content.segments.contains { $0.id == id && $0.isWord }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { contentChanged() }
    }

    private func contentChanged() {
        needsDisplay = true
        elements = nil
        toolTipWidth = nil
        window?.invalidateCursorRects(for: self)
        updateToolTips()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let fonts = ReadingFonts.of(content.style, content.typeface)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for item in current.items(in: dirtyRect) {
            if let segment = item.segment { drawMarks(of: segment, in: item.frame) }
            for run in item.runs {
                let color = run.tone.map(ToneColor.nsColor) ?? .labelColor
                context.setFillColor(color.cgColor)
                context.textPosition = run.origin
                CTLineDraw(fonts.line(run.text, run.face), context)
                if run.face == .pinyin, item.segment?.readingCorrected == true { drawDots(under: run) }
            }
        }
    }

    private func drawMarks(of segment: Segment, in frame: CGRect) {
        if segment.id == selectedID {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.75, dy: 0.75), xRadius: 5.25, yRadius: 5.25)
            outline.lineWidth = 1.5
            outline.stroke()
        }
        if content.saved.contains(segment.text) {
            Sheet.savedNSColor.setFill()
            let line = CGRect(x: frame.minX + 4, y: frame.maxY - 1.5, width: frame.width - 8, height: 2.5)
            NSBezierPath(roundedRect: line, xRadius: 1.25, yRadius: 1.25).fill()
        }
    }

    /// A context reading is underlined with dots, so it shows without relying on colour.
    private func drawDots(under run: ReadingLayout.Run) {
        let y = run.origin.y + ReadingFonts.of(content.style, content.typeface).descent(of: .pinyin) + 1
        let path = NSBezierPath()
        path.move(to: CGPoint(x: run.origin.x + 2, y: y))
        path.line(to: CGPoint(x: run.origin.x + run.width - 2, y: y))
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        path.setLineDash([0.1, 3], count: 2, phase: 0)
        Sheet.correctedNSColor.setStroke()
        path.stroke()
    }

    // MARK: Pointer

    private func segment(at event: NSEvent) -> Segment? {
        segment(at: convert(event.locationInWindow, from: nil))
    }

    private func segment(at point: CGPoint) -> Segment? {
        let layout = current
        return layout.word(at: point).flatMap { layout.items[$0].segment }
    }

    private var pressed: Segment?

    override func mouseDown(with event: NSEvent) {
        pressed = segment(at: event)
        // A control-click brings up the menu instead.
        if event.modifierFlags.contains(.control) { pressed = nil; super.mouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard let pressed, segment(at: event)?.id == pressed.id else { return }
        actions?.select(pressed)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let items = actions?.menu(for: segment(at: event)), !items.isEmpty else { return nil }
        let menu = NSMenu()
        for item in items {
            switch item {
            case .separator: menu.addItem(.separator())
            case .action(let title, let action): menu.addItem(ActionMenuItem(title: title, action: action))
            }
        }
        return menu
    }

    // MARK: Tooltips

    private func updateToolTips() {
        guard toolTipWidth != bounds.width, bounds.width > 0 else { return }
        toolTipWidth = bounds.width
        removeAllToolTips()
        for item in current.items where item.segment != nil {
            addToolTip(item.frame, owner: self, userData: nil)
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let segment = segment(at: point) else { return "" }
        var lines = ["\(segment.text) \(segment.pinyin)"]
        if segment.readingCorrected {
            lines.append("Context reading: the AI changed the dictionary's \(segment.alternativeReadings.first ?? "reading")")
        }
        if !segment.gloss.isEmpty { lines.append(segment.gloss) }
        if content.saved.contains(segment.text) { lines.append("★ In your Vocabulary") }
        return lines.joined(separator: "\n")
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Reading" }

    override func accessibilityChildren() -> [Any]? {
        if let elements { return elements }
        let made = current.items.map { item -> NSAccessibilityElement in
            guard let segment = item.segment else {
                return ReadingElement(view: self, frame: item.frame, role: .staticText, label: item.runs.map(\.text).joined())
            }
            let element = ReadingElement(view: self, frame: item.frame, role: .button, label: label(for: segment)) { [weak self] in
                self?.actions?.select(segment)
            }
            element.setAccessibilityHelp("Shows what it means")
            element.setAccessibilitySelected(segment.id == selectedID)
            return element
        }
        elements = made
        return made
    }

    private func label(for segment: Segment) -> String {
        var parts = [content.showTraditional ? segment.original : segment.text, segment.pinyin]
        if segment.readingCorrected { parts.append("context reading") }
        if let first = segment.definitions.first ?? segment.addOnGlosses.first?.text { parts.append(first) }
        if content.saved.contains(segment.text) { parts.append("in your Vocabulary") }
        return parts.joined(separator: ", ")
    }
}

/// One word (or run of English) to VoiceOver.
private final class ReadingElement: NSAccessibilityElement {
    private weak var view: NSView?
    private let frame: CGRect
    private let press: (() -> Void)?

    init(view: NSView, frame: CGRect, role: NSAccessibility.Role, label: String, press: (() -> Void)? = nil) {
        self.view = view
        self.frame = frame
        self.press = press
        super.init()
        setAccessibilityRole(role)
        setAccessibilityParent(view)
        if role == .staticText { setAccessibilityValue(label) } else { setAccessibilityLabel(label) }
    }

    override func accessibilityFrame() -> NSRect {
        MainActor.assumeIsolated { view.map { NSAccessibility.screenRect(fromView: $0, rect: frame) } ?? .zero }
    }

    override func accessibilityPerformPress() -> Bool {
        press?()
        return press != nil
    }
}

private final class ActionMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, action run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(perform(_:)), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func perform(_ sender: Any?) { run() }
}
