import SwiftUI
import KandongKit

struct ResultView: View {
    let model: AppModel
    let controller: ResultPanelController

    var body: some View {
        Group {
            if let session = model.session {
                SessionView(model: model, controller: controller, session: session)
            } else {
                Text(model.lookupHint)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.regularMaterial)
        // The header shares the title bar's row, next to the close button.
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct SessionView: View {
    let model: AppModel
    let controller: ResultPanelController
    @Bindable var session: LookupSession
    @ViewState private var showAllWords = false

    private static let longTextThreshold = 1500

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .frame(height: 30)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let message = session.message {
                        Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        content
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Label(headerTitle, systemImage: sourceIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if session.analysis?.containsTraditional == true {
                Toggle("繁", isOn: $session.showTraditional)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Show the original Traditional characters")
            }
            if let analysis = session.analysis, analysis.hasChinese {
                Button { Speech.speak(analysis.source) } label: { Image(systemName: "speaker.wave.2") }
                    .buttonStyle(.borderless)
                    .help("Read aloud")
            }
            BackendBadge(model: model, session: session)
            Button { controller.togglePin() } label: {
                Image(systemName: controller.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(controller.isPinned ? "Unpin" : "Pin: keep open when clicking elsewhere")
        }
        .padding(.leading, 60) // clear the window's close button
    }

    private var headerTitle: String {
        session.direction == .reverse ? "Say it in Chinese" : session.source.displayName
    }

    private var sourceIcon: String {
        switch session.source {
        case .selection: "text.cursor"
        case .screenCapture: "camera.viewfinder"
        case .clipboard: "doc.on.clipboard"
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if session.status == .readingImage {
            ProgressRow(text: "Reading the image…")
        }
        if session.direction == .reverse {
            Text(session.sourceText)
                .font(.title3)
                .textSelection(.enabled)
        }
        if let analysis = session.analysis, analysis.hasChinese {
            ReadingView(model: model, analysis: analysis, showTraditional: session.showTraditional)
            if session.direction == .reverse, let chinese = session.translation {
                CopyButton(text: chinese, label: "Copy Chinese")
            }
        }
        translationSection
        if session.analysis?.hasChinese == true, session.status != .readingImage {
            explanationSection
            breakdownSection
        }
    }

    @ViewBuilder private var translationSection: some View {
        switch session.status {
        case .translating:
            // The Translation types out as it comes in (Reverse's Chinese shows once it's read).
            if let progress = session.progress, session.direction == .learn, !progress.translation.isEmpty {
                TranslationBox(text: progress.translation)
            }
            if let progress = session.progress, progress.isInParts {
                ProgressRow(text: partProgressText(progress) + (session.isThinking ? " Thinking…" : ""))
            } else if session.isThinking {
                ProgressRow(text: "Thinking before it answers…")
            } else if session.progress?.translation.isEmpty ?? true || session.direction == .reverse {
                ProgressRow(text: session.direction == .reverse ? "Finding the Chinese…" : "Translating…")
            }
        case .failed(let message):
            FailureCard(model: model, session: session, config: session.backend, message: message)
        case .done, .readingImage:
            if session.direction == .learn, let translation = session.translation {
                TranslationBox(text: translation, copyable: true)
            }
            if let note = session.note {
                Text(note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    /// "Long text — translating part 2 of 4…"; the count is unknown while a Backend is still halving.
    private func partProgressText(_ progress: LookupProgress) -> String {
        if let total = progress.totalParts, progress.completedParts >= total { return "Long text — finishing…" }
        let of = progress.totalParts.map { " of \($0)" } ?? ""
        return "Long text — translating part \(progress.completedParts + 1)\(of)…"
    }

    @ViewBuilder private var explanationSection: some View {
        if session.explanation.isEmpty && !session.isExplaining {
            HStack {
                Button {
                    model.explain(session)
                } label: {
                    Label("Explain", systemImage: "graduationcap")
                }
            }
            if let error = session.explanationError {
                FailureCard(model: model, session: session, config: session.explanationBackend ?? session.backend, message: error)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let other = session.explanationBackend, other.id != session.backendID {
                    SectionTitle("Explanation · \(other.name)")
                } else {
                    SectionTitle("Explanation")
                }
                MarkdownText(markdown: Prompts.visibleText(session.explanation))
                if session.isExplanationThinking {
                    ProgressRow(text: "Thinking before it answers…")
                } else if session.isExplaining {
                    ProgressView().controlSize(.small)
                }
                if let error = session.explanationError, !session.explanation.isEmpty {
                    Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
                if session.hasMoreToExplain, let parts = session.explanationParts {
                    Button {
                        model.explain(session)
                    } label: {
                        let next = "part \(parts.done + 1) of \(parts.count)"
                        Label(session.explanationError == nil ? "Explain next \(next)" : "Retry \(next)", systemImage: "graduationcap")
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private var breakdownSection: some View {
        if let analysis = session.analysis {
            let words = analysis.uniqueWords
            let known = words.filter(model.isKnown)
            let unknown = words.filter { !model.isKnown($0) }
            let isLong = session.sourceText.count > Self.longTextThreshold
            let shown = isLong && !showAllWords ? Array(unknown.prefix(40)) : unknown
            let encounters = model.encounterCounts()
            VStack(alignment: .leading, spacing: 4) {
                SectionTitle("Words")
                ForEach(shown) { word in
                    WordRow(model: model, word: word, sentence: analysis.source, encounters: encounters[word.text] ?? 0,
                            showTraditional: session.showTraditional)
                    Divider().opacity(0.4)
                }
                if shown.count < unknown.count {
                    Button("Show all \(unknown.count) words") { showAllWords = true }.controlSize(.small)
                }
                if !known.isEmpty {
                    DisclosureGroup("\(known.count) known word\(known.count == 1 ? "" : "s") (≤ \(HSKTable.label(for: model.settings.myLevel)))") {
                        ForEach(known) { word in
                            WordRow(model: model, word: word, sentence: analysis.source, encounters: encounters[word.text] ?? 0,
                                    showTraditional: session.showTraditional)
                                .opacity(0.6)
                        }
                    }
                    .font(.callout)
                }
            }
        }
    }
}

// MARK: - Reading

/// The text with pinyin above each character, coloured by tone.
private struct ReadingView: View {
    let model: AppModel
    let analysis: OfflineAnalysis
    let showTraditional: Bool

    var body: some View {
        let saved = Set(model.workspace.vocabulary().map(\.simplified))
        let _ = model.workspaceRevision
        FlowLayout(lineSpacing: 6) {
            ForEach(units(saved: saved)) { unit in
                switch unit.kind {
                case .lineBreak:
                    Color.clear.frame(width: 0, height: 0).layoutValue(key: LineBreakKey.self, value: true)
                case .text(let text):
                    VStack(spacing: 1) {
                        Text(" ").font(.system(size: 11))
                        Text(text).font(.system(size: 17)).foregroundStyle(.secondary)
                    }
                case .word(let segment, let isSaved):
                    RubyWord(segment: segment, showTraditional: showTraditional,
                             hidePinyin: model.settings.pinyinForUnknownOnly && model.isKnown(segment), isSaved: isSaved)
                }
            }
        }
        .textSelection(.enabled)
    }

    private struct Unit: Identifiable {
        enum Kind {
            case word(Segment, isSaved: Bool)
            case text(String)
            case lineBreak
        }
        let id: Int
        let kind: Kind
    }

    private func units(saved: Set<String>) -> [Unit] {
        var units: [Unit] = []
        for segment in analysis.segments {
            if segment.isWord {
                units.append(Unit(id: units.count, kind: .word(segment, isSaved: saved.contains(segment.text))))
                continue
            }
            // Pass-through text: keep line breaks, split long runs at spaces so they can wrap.
            let lines = segment.original.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                if index > 0 { units.append(Unit(id: units.count, kind: .lineBreak)) }
                for piece in line.split(separator: " ", omittingEmptySubsequences: false) where !piece.isEmpty {
                    units.append(Unit(id: units.count, kind: .text(String(piece))))
                }
            }
        }
        return units
    }
}

private struct RubyWord: View {
    let segment: Segment
    let showTraditional: Bool
    let hidePinyin: Bool
    let isSaved: Bool

    var body: some View {
        let characters = Array(showTraditional ? segment.original : segment.text)
        HStack(alignment: .bottom, spacing: 0) {
            if segment.isAligned && characters.count == segment.syllables.count {
                ForEach(Array(zip(characters, segment.syllables).enumerated()), id: \.offset) { _, pair in
                    cell(String(pair.0), pinyin: pair.1.text, tone: pair.1.tone)
                }
            } else {
                cell(String(characters), pinyin: segment.pinyin, tone: segment.syllables.first?.tone ?? 5)
            }
        }
        .padding(.horizontal, 1)
        .overlay(alignment: .bottom) {
            if isSaved {
                Rectangle().fill(Color.yellow.opacity(0.8)).frame(height: 2).offset(y: 2)
            }
        }
        .background(segment.readingCorrected ? Color.orange.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .help(tooltip)
        .onTapGesture { Speech.speak(segment.text) }
    }

    private func cell(_ character: String, pinyin: String, tone: Int) -> some View {
        VStack(spacing: 1) {
            Text(hidePinyin ? " " : pinyin)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ToneColor.color(tone))
                .fixedSize()
            Text(character).font(.system(size: 22))
        }
        .padding(.horizontal, 1)
    }

    private var tooltip: String {
        var lines = ["\(segment.text) \(segment.pinyin)"]
        if segment.readingCorrected { lines.append("Reading corrected for this context") }
        if !segment.gloss.isEmpty { lines.append(segment.gloss) }
        if isSaved { lines.append("★ In your Vocabulary") }
        return lines.joined(separator: "\n")
    }
}

enum ToneColor {
    /// Pleco-style tone colours.
    static func color(_ tone: Int) -> Color {
        switch tone {
        case 1: Color(red: 0.89, green: 0.22, blue: 0.21)
        case 2: Color(red: 0.20, green: 0.66, blue: 0.33)
        case 3: Color(red: 0.20, green: 0.45, blue: 0.90)
        case 4: Color(red: 0.62, green: 0.33, blue: 0.85)
        default: Color.gray
        }
    }
}

// MARK: - Word breakdown

private struct WordRow: View {
    let model: AppModel
    let word: Segment
    let sentence: String
    let encounters: Int
    let showTraditional: Bool
    @ViewState private var addingTerm = false

    var body: some View {
        let isSaved = model.isSaved(word.text)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(word.text).font(.system(size: 18))
                    if word.isTraditional {
                        Text(word.original).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 0) {
                    ForEach(Array(word.syllables.enumerated()), id: \.offset) { index, syllable in
                        Text((index > 0 ? " " : "") + syllable.text).foregroundStyle(ToneColor.color(syllable.tone))
                    }
                }
                .font(.system(size: 12, weight: .medium))
            }
            .frame(minWidth: 70, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if let level = word.hskLevel { Chip(HSKTable.label(for: level)) }
                    if word.readingCorrected { Chip("context reading", color: .orange) }
                    if encounters > 0 { Chip("★ seen \(encounters)×", color: .yellow) }
                    if let term = model.term(for: word.text) { Chip("Term: \(term.english)", color: .blue) }
                }
                Text(word.gloss.isEmpty ? "—" : word.gloss)
                    .font(.callout)
                    .lineLimit(3)
                    .help(word.definitions.joined(separator: "\n"))
                if !word.alternativeReadings.isEmpty {
                    Text("also: " + word.alternativeReadings.prefix(3).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Button { Speech.speak(word.text) } label: { Image(systemName: "speaker.wave.1") }
                    .help("Say \(word.text)")
                Button { addingTerm = true } label: { Image(systemName: "text.badge.plus") }
                    .help("Add to Terms (how this should be translated)")
                    .popover(isPresented: $addingTerm) {
                        TermEditor(model: model, word: word) { addingTerm = false }
                    }
                Button { model.toggleSaved(word, sentence: sentence) } label: {
                    Image(systemName: isSaved ? "star.fill" : "star").foregroundStyle(isSaved ? .yellow : .secondary)
                }
                .help(isSaved ? "Remove from Vocabulary" : "Save to Vocabulary")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
    }
}

private struct TermEditor: View {
    let model: AppModel
    let word: Segment
    let done: () -> Void
    @ViewState private var english = ""
    @ViewState private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Always translate **\(word.text)** as:").font(.callout)
            TextField("English", text: $english).frame(width: 240)
            TextField("Note (optional)", text: $note)
            HStack {
                Spacer()
                Button("Cancel", action: done)
                Button("Save Term") {
                    model.addTerm(Term(chinese: word.text, english: english, note: note))
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(english.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .onAppear {
            if let term = model.term(for: word.text) {
                english = term.english
                note = term.note
            } else {
                english = word.definitions.first.map { $0.replacingOccurrences(of: #"\s*\(.*?\)"#, with: "", options: .regularExpression) } ?? ""
            }
        }
    }
}

// MARK: - Small pieces

private struct TranslationBox: View {
    let text: String
    var copyable = false

    var body: some View {
        Text(text)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .padding(.trailing, copyable ? 22 : 0)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                if copyable { CopyButton(text: text).labelStyle(.iconOnly).padding(6) }
            }
    }
}

private struct CopyButton: View {
    let text: String
    var label = "Copy"
    @ViewState private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(label)
    }
}

/// Why the AI couldn't answer, how to fix it, and which other Backends could answer instead.
private struct FailureCard: View {
    let model: AppModel
    let session: LookupSession
    /// The Backend that failed.
    let config: BackendConfig
    let message: String

    var body: some View {
        let status = model.statuses[config.id]
        let alternatives = model.settings.backends.filter { $0.id != config.id && model.statuses[$0.id]?.isReady == true }
        VStack(alignment: .leading, spacing: 8) {
            Label(status.map { $0.isReady ? message : $0.message } ?? message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                if let fix = status?.fix {
                    Button(model.title(for: fix)) { model.perform(fix) }
                }
                Button("AI settings…") { AppDelegate.shared?.showMainWindow(tab: .ai) }
            }
            .controlSize(.small)
            if !alternatives.isEmpty {
                HStack(spacing: 6) {
                    Text("Try with:").font(.caption).foregroundStyle(.secondary)
                    ForEach(alternatives) { config in
                        Button {
                            model.retry(session, with: config)
                        } label: {
                            Label(config.name, systemImage: config.isOnDevice ? "desktopcomputer" : "cloud")
                        }
                        .help(config.isOnDevice ? "Text stays on this Mac" : "Text is sent to \(config.name)")
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .task { await model.refreshStatuses() }
    }
}

/// Which Backend answered; click to ask another one or make this one the default.
private struct BackendBadge: View {
    let model: AppModel
    let session: LookupSession

    var body: some View {
        let isLocal = session.backendIsLocal
        Menu {
            Section("Try with") {
                ForEach(model.settings.backends.filter { $0.id != session.backendID }) { config in
                    Button {
                        model.retry(session, with: config)
                    } label: {
                        let status = model.statuses[config.id]
                        Text(config.name + (status.map { $0.isReady ? "" : " — \($0.message)" } ?? ""))
                    }
                    .disabled(model.statuses[config.id].map { !$0.isReady } ?? false)
                }
            }
            if model.settings.defaultBackendID != session.backendID, let config = model.settings.backend(id: session.backendID) {
                Button("Make \(config.name) the Default") { model.settings.defaultBackendID = config.id }
            }
            Button("AI Settings…") { AppDelegate.shared?.showMainWindow(tab: .ai) }
        } label: {
            Label(session.backendLabel, systemImage: isLocal ? "desktopcomputer" : "cloud")
                .font(.caption2)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(isLocal ? Color.green.opacity(0.15) : Color.blue.opacity(0.12), in: Capsule())
        .help((isLocal ? "Text stays on this Mac" : "Text is sent to \(session.backendLabel)") + " — click to try another Backend")
        .task { if model.statuses.isEmpty { await model.refreshStatuses() } }
    }
}


private struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }
}

private struct ProgressRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

/// Renders the Explanation's Markdown: headings, bullets and inline styling.
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(MarkdownLines.parse(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .blank:
                    Color.clear.frame(height: 2)
                case .heading(let text):
                    inline(text).font(.headline)
                case .bullet(let level, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        inline(text)
                    }
                    .padding(.leading, CGFloat(level) * 12)
                case .paragraph(let text):
                    inline(text)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }
}

// MARK: - Flow layout

struct LineBreakKey: LayoutValueKey {
    static let defaultValue = false
}

/// Lays children left-to-right, wrapping to new lines; a child marked with `LineBreakKey` forces a break.
struct FlowLayout: Layout {
    var spacing: CGFloat = 2
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, size) in zip(row.indices, row.sizes) {
                subviews[index].place(at: CGPoint(x: x, y: y + row.height - size.height), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            if subview[LineBreakKey.self] {
                rows.append(Row())
                continue
            }
            let size = subview.sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            row.sizes.append(size)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty || rows.count == 1 }
    }
}
