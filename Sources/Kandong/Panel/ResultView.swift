import SwiftUI
import KandongKit

/// The panel's content: a header on the glass, and the Result on a solid sheet inside it.
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
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The header shares the title bar's row, next to the close button.
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct SessionView: View {
    let model: AppModel
    let controller: ResultPanelController
    @Bindable var session: LookupSession
    @ViewState private var showAllWords = false
    @ViewState private var contentHeight: CGFloat = 0
    @ViewState private var viewportHeight: CGFloat = 0

    private static let longTextThreshold = 1500
    /// Gap between the glass edge and the sheet; the sheet's corners stay concentric with the panel's.
    private static let inset: CGFloat = 6

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(model: model, controller: controller, session: session)
                .frame(height: controller.titlebarHeight)
                .padding(.leading, controller.closeButtonInset)
                .padding(.trailing, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let message = session.message {
                        Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        content
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0; fit() }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { viewportHeight = $0; fit() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let word = controller.selectedWord, let analysis = session.analysis {
                    WordCard(model: model, controller: controller, word: word, sentence: analysis.source,
                             typeface: model.settings.readingTypeface, showTraditional: session.showTraditional)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.22), value: controller.selectedWordID)
            .background(Sheet.background, in: RoundedRectangle(cornerRadius: ResultPanelController.cornerRadius - Self.inset))
            .clipShape(RoundedRectangle(cornerRadius: ResultPanelController.cornerRadius - Self.inset))
            .padding([.horizontal, .bottom], Self.inset)
        }
    }

    private func fit() {
        controller.fit(contentHeight: contentHeight, viewportHeight: viewportHeight)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if session.status == .readingImage {
            ProgressRow(text: "Reading the image…")
        }
        if session.direction == .reverse {
            Text(session.sourceText)
                .font(.title3)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        if let analysis = session.analysis, analysis.hasChinese {
            ReadingView(model: model, controller: controller, analysis: analysis, showTraditional: session.showTraditional)
        }
        translationSection
        if session.analysis?.hasChinese == true, session.status != .readingImage {
            actions
            explanationSection
            levelQuestion
            breakdownSection
        }
    }

    @ViewBuilder private var translationSection: some View {
        switch session.status {
        case .translating:
            // The Translation types out as it comes in (Reverse's Chinese shows once it's read).
            if let progress = session.progress, session.direction == .learn, !progress.translation.isEmpty {
                TranslationText(text: progress.translation)
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
                TranslationText(text: translation)
            }
            if let note = session.note {
                Text(note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if session.isReopened {
                Text("From History. Readings are the dictionary's; look it up again for context readings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// "Long text — translating part 2 of 4…"; the count is unknown while a Backend is still halving.
    private func partProgressText(_ progress: LookupProgress) -> String {
        if let total = progress.totalParts, progress.completedParts >= total { return "Long text — finishing…" }
        let of = progress.totalParts.map { " of \($0)" } ?? ""
        return "Long text — translating part \(progress.completedParts + 1)\(of)…"
    }

    /// Copy (Reverse's answer comes first), Explain, and saying it the other way.
    @ViewBuilder private var actions: some View {
        let canExplain = session.explanation.isEmpty && !session.isExplaining
        let answer = session.direction == .reverse ? session.translation : session.translation.flatMap { $0.isEmpty ? nil : $0 }
        if canExplain || answer != nil {
            HStack(spacing: 8) {
                if let answer {
                    if session.direction == .reverse {
                        CopyButton(text: answer, label: "Copy Chinese")
                            .buttonStyle(.borderedProminent)
                    } else {
                        CopyButton(text: answer, label: "Copy translation")
                            .buttonStyle(.bordered)
                    }
                }
                if canExplain {
                    Button { model.explain(session) } label: { Label("Explain", systemImage: "graduationcap") }
                        .buttonStyle(.bordered)
                        .disabled(session.status == .translating)
                        .help("Grammar and usage notes (E)")
                }
            }
            .controlSize(.regular)
        }
    }

    @ViewBuilder private var explanationSection: some View {
        if session.explanation.isEmpty && !session.isExplaining {
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
                MarkdownText(markdown: Prompts.unfenced(Prompts.visibleText(session.explanation)))
                if session.isExplanationThinking {
                    ProgressRow(text: "Thinking before it answers…")
                } else if session.isExplaining {
                    ProgressView().controlSize(.small)
                }
                if let error = session.explanationError, !session.explanation.isEmpty {
                    Text(error).font(.callout).foregroundStyle(Sheet.corrected).textSelection(.enabled)
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

    /// Asked once: which words to fold away as already known.
    @ViewBuilder private var levelQuestion: some View {
        if !model.settings.hasChosenLevel, model.settings.myLevel == 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Fold away words you already know?").font(.callout.weight(.medium))
                HStack(spacing: 6) {
                    Text("Up to").font(.callout).foregroundStyle(.secondary)
                    ForEach(1...6, id: \.self) { level in
                        Button("HSK \(level)") {
                            model.settings.myLevel = level
                            model.settings.hasChosenLevel = true
                        }
                    }
                    Button("Not now") { model.settings.hasChosenLevel = true }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
                .controlSize(.small)
                Text("You can change this in Settings → Learning.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder private var breakdownSection: some View {
        if let analysis = session.analysis {
            let words = analysis.uniqueWords
            let known = words.filter(model.isKnown)
            let unknown = words.filter { !model.isKnown($0) }
            let isLong = session.sourceText.count > Self.longTextThreshold
            let shown = isLong && !showAllWords ? Array(unknown.prefix(40)) : unknown
            let saved = Set(model.workspace.vocabulary().map(\.simplified))
            let _ = model.workspaceRevision
            VStack(alignment: .leading, spacing: 2) {
                if !unknown.isEmpty {
                    SectionTitle(known.isEmpty ? "Words" : "New words")
                        .padding(.bottom, 4)
                }
                ForEach(shown) { word in
                    WordRow(controller: controller, word: word, isSaved: saved.contains(word.text), typeface: model.settings.readingTypeface)
                }
                if shown.count < unknown.count {
                    Button("Show all \(unknown.count) words") { showAllWords = true }
                        .controlSize(.small)
                        .padding(.top, 4)
                }
                if !known.isEmpty {
                    DisclosureGroup {
                        ForEach(known) { word in
                            WordRow(controller: controller, word: word, isSaved: saved.contains(word.text), typeface: model.settings.readingTypeface)
                        }
                    } label: {
                        Text("\(known.count) known word\(known.count == 1 ? "" : "s") (up to \(HSKTable.label(for: model.settings.myLevel)))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }
            }
        }
    }
}

// MARK: - Header

/// Where the text came from, which way it's read, and which Backend answered, on the glass.
private struct PanelHeader: View {
    let model: AppModel
    let controller: ResultPanelController
    @Bindable var session: LookupSession

    var body: some View {
        HStack(spacing: 10) {
            Label(session.source.displayName, systemImage: session.source.symbolName)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            directionToken
            Spacer(minLength: 4)
            if session.analysis?.containsTraditional == true {
                Toggle("繁", isOn: $session.showTraditional)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Show the original Traditional characters")
                    .accessibilityLabel("Traditional characters")
            }
            if let analysis = session.analysis, analysis.hasChinese {
                Button { Speech.speak(analysis.source) } label: { Image(systemName: "speaker.wave.2") }
                    .buttonStyle(.borderless)
                    .help("Read the text aloud (Space)")
                    .accessibilityLabel("Read aloud")
            }
            BackendBadge(model: model, session: session)
            Button { controller.togglePin() } label: {
                Image(systemName: controller.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(controller.isPinned ? "Unpin (P)" : "Pin: keep open when clicking elsewhere (P)")
            .accessibilityLabel("Pin")
            .accessibilityValue(controller.isPinned ? "On" : "Off")
        }
    }

    /// "中 → EN" or "EN → 中": a button when the text mixes both, so it can be read the other way.
    @ViewBuilder private var directionToken: some View {
        let label = session.direction == .learn ? "中 → EN" : "EN → 中"
        if session.canFlip {
            Button { model.flip(session) } label: {
                HStack(spacing: 4) {
                    Text(label)
                    Image(systemName: "arrow.left.arrow.right").imageScale(.small)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(session.direction == .learn ? "Say it all in Chinese instead (R, or look it up again)" : "Translate it into English instead (R, or look it up again)")
            .accessibilityLabel(session.direction == .learn ? "Reading Chinese into English. Switch to saying it in Chinese" : "Saying it in Chinese. Switch to translating into English")
        } else if session.direction == .reverse {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("Saying English in Chinese")
                .accessibilityLabel("Saying it in Chinese")
        }
    }
}

/// Which Backend answered; click to ask another one or make this one the default.
private struct BackendBadge: View {
    let model: AppModel
    let session: LookupSession

    var body: some View {
        let isLocal = session.backendIsLocal
        let where_ = isLocal ? "Text stays on this Mac" : "Text is sent to \(session.backendLabel)"
        Menu {
            Section("Try with") {
                ForEach(model.settings.backends.filter { $0.id != session.backendID }) { config in
                    Button {
                        model.retry(session, with: config)
                    } label: {
                        let status = model.statuses[config.id]
                        Label(config.name + (status.map { $0.isReady ? "" : " — \($0.message)" } ?? ""),
                              systemImage: config.isOnDevice ? "desktopcomputer" : "cloud")
                    }
                    .disabled(model.statuses[config.id].map { !$0.isReady } ?? false)
                }
            }
            if model.settings.defaultBackendID != session.backendID, let config = model.settings.backend(id: session.backendID) {
                Button("Make \(config.name) the Default") { model.settings.defaultBackendID = config.id }
            }
            Button("AI Settings…") { AppDelegate.shared?.showMainWindow(tab: .ai) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isLocal ? "desktopcomputer" : "cloud")
                    .foregroundStyle(isLocal ? Color.green : Color.blue)
                Text(session.backend.name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.callout.weight(.medium))
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .frame(maxWidth: 160)
        .fixedSize(horizontal: false, vertical: true)
        .help("\(session.backendLabel) · \(where_). Click to try another Backend.")
        .accessibilityLabel("Answered by \(session.backend.name). \(where_)")
        .task { if model.statuses.isEmpty { await model.refreshStatuses() } }
    }
}

// MARK: - Reading

/// The text with pinyin above each character, coloured by tone. Click a word (or use ←/→) to see
/// what it means in the word card.
private struct ReadingView: View {
    let model: AppModel
    let controller: ResultPanelController
    let analysis: OfflineAnalysis
    let showTraditional: Bool

    /// The Chinese is set large: it's what the user is here to read.
    private static let characterSize: CGFloat = 26

    var body: some View {
        let saved = Set(model.workspace.vocabulary().map(\.simplified))
        let _ = model.workspaceRevision
        let typeface = model.settings.readingTypeface
        FlowLayout(spacing: 6, lineSpacing: 10) {
            ForEach(units(saved: saved)) { unit in
                Group {
                    switch unit.kind {
                    case .lineBreak:
                        Color.clear.frame(width: 0, height: 0).layoutValue(key: LineBreakKey.self, value: true)
                    case .text(let text):
                        VStack(spacing: 2) {
                            Text(" ").font(.system(size: 12))
                            Text(text)
                                .font(.system(size: Self.characterSize * 0.7))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel(text)
                    case .word(let segment, let isSaved):
                        RubyWord(segment: segment, showTraditional: showTraditional,
                                 hidePinyin: model.settings.pinyinForUnknownOnly && model.isKnown(segment),
                                 isSaved: isSaved, isSelected: controller.selectedWordID == segment.id,
                                 characterFont: ReadingFont.font(size: Self.characterSize, typeface: typeface),
                                 cellWidth: Self.characterSize * 1.2) {
                            controller.selectedWordID = controller.selectedWordID == segment.id ? nil : segment.id
                        }
                        .contextMenu {
                            Button("Say \(segment.text)") { Speech.speak(segment.text) }
                            Button(isSaved ? "Remove from Vocabulary" : "Save to Vocabulary") {
                                model.toggleSaved(segment, sentence: analysis.source)
                            }
                            Divider()
                            Button("Copy \(segment.text)") { Pasteboard.copy(segment.text) }
                            Button("Copy Text") { Pasteboard.copy(analysis.source) }
                        }
                    }
                }
                .layoutValue(key: GlueKey.self, value: unit.gluedToPrevious)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reading")
    }

    private struct Unit: Identifiable {
        enum Kind {
            case word(Segment, isSaved: Bool)
            case text(String)
            case lineBreak
        }
        let id: Int
        let kind: Kind
        /// Sits right after the previous unit with no gap: punctuation, or a name after "@".
        var gluedToPrevious = false
    }

    private static let closingPunctuation = Set("，。、！？；：,.!?;:)）」』”’…%")

    private func units(saved: Set<String>) -> [Unit] {
        var units: [Unit] = []
        var glueNext = false
        for segment in analysis.segments {
            if segment.isWord {
                units.append(Unit(id: units.count, kind: .word(segment, isSaved: saved.contains(segment.text)), gluedToPrevious: glueNext))
                glueNext = false
                continue
            }
            // Pass-through text: keep line breaks, split long runs at spaces so they can wrap.
            let lines = segment.original.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                if index > 0 { units.append(Unit(id: units.count, kind: .lineBreak)) }
                let startsWithSpace = line.first?.isWhitespace ?? false
                let pieces = line.split(separator: " ", omittingEmptySubsequences: true)
                for (pieceIndex, piece) in pieces.enumerated() {
                    let text = String(piece)
                    let isPunctuation = text.allSatisfy { Self.closingPunctuation.contains($0) }
                    let glued = (pieceIndex == 0 && !startsWithSpace && (isPunctuation || glueNext))
                    units.append(Unit(id: units.count, kind: .text(text), gluedToPrevious: glued))
                    glueNext = false
                }
                // "@" or "#" right before a word: keep the word attached (@张三).
                glueNext = !(line.last?.isWhitespace ?? true) && (line.hasSuffix("@") || line.hasSuffix("#") || line.hasSuffix("“") || line.hasSuffix("（"))
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
    let isSelected: Bool
    let characterFont: Font
    let cellWidth: CGFloat
    let select: () -> Void

    var body: some View {
        let characters = Array(showTraditional ? segment.original : segment.text)
        Button(action: select) {
            HStack(alignment: .bottom, spacing: 0) {
                if segment.isAligned && characters.count == segment.syllables.count {
                    ForEach(Array(zip(characters, segment.syllables).enumerated()), id: \.offset) { _, pair in
                        cell(String(pair.0), pinyin: pair.1.text, tone: pair.1.tone, width: cellWidth)
                    }
                } else {
                    cell(String(characters), pinyin: segment.pinyin, tone: segment.syllables.first?.tone ?? 5, width: nil)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
            .overlay(alignment: .bottom) {
                if isSaved {
                    Capsule().fill(Sheet.saved).frame(height: 2.5).padding(.horizontal, 4).offset(y: 1)
                }
            }
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.14))
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Shows what it means")
    }

    private func cell(_ character: String, pinyin: String, tone: Int, width: CGFloat?) -> some View {
        VStack(spacing: 2) {
            Text(hidePinyin ? " " : pinyin)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ToneColor.color(tone))
                .fixedSize()
                // A context reading is underlined with dots, so it shows without relying on colour.
                .overlay(alignment: .bottom) {
                    if segment.readingCorrected && !hidePinyin {
                        Line().stroke(Sheet.corrected, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [0.1, 3]))
                            .frame(height: 1).offset(y: 2)
                    }
                }
            Text(character).font(characterFont)
        }
        // Even cells keep the characters' rhythm; only a long syllable (zhuàng) widens its own,
        // keeping a hair of space from its neighbour's pinyin.
        .padding(.horizontal, 1.5)
        .frame(minWidth: width)
    }

    private var tooltip: String {
        var lines = ["\(segment.text) \(segment.pinyin)"]
        if segment.readingCorrected { lines.append("Context reading: the AI changed the dictionary's \(segment.alternativeReadings.first ?? "reading")") }
        if !segment.gloss.isEmpty { lines.append(segment.gloss) }
        if isSaved { lines.append("★ In your Vocabulary") }
        return lines.joined(separator: "\n")
    }

    private var accessibilityText: String {
        var parts = [showTraditional ? segment.original : segment.text, segment.pinyin]
        if segment.readingCorrected { parts.append("context reading") }
        if let first = segment.definitions.first ?? segment.addOnGlosses.first?.text { parts.append(first) }
        if isSaved { parts.append("in your Vocabulary") }
        return parts.joined(separator: ", ")
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX + 2, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.midY))
        }
    }
}

// MARK: - Word card

/// What the selected word means, docked at the bottom of the sheet, with what can be done with it.
private struct WordCard: View {
    let model: AppModel
    let controller: ResultPanelController
    let word: Segment
    let sentence: String
    let typeface: ReadingTypeface
    let showTraditional: Bool
    @ViewState private var addingTerm = false

    var body: some View {
        let isSaved = model.isSaved(word.text)
        let encounters = model.encounterCounts()[word.text] ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(showTraditional ? word.original : word.text)
                    .font(ReadingFont.font(size: 30, typeface: typeface))
                    .textSelection(.enabled)
                PinyinText(syllables: word.syllables)
                    .font(.system(size: 15, weight: .medium))
                Spacer(minLength: 8)
                Button { controller.selectedWordID = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Close (Esc)")
                    .accessibilityLabel("Close word")
            }
            facts(encounters: encounters)
            if !word.gloss.isEmpty {
                Text(Gloss.clean(word.definitions.isEmpty ? word.gloss : word.definitions.prefix(4).joined(separator: "; ")))
                    .font(.body)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .help(word.definitions.joined(separator: "\n"))
            }
            // An add-on's sense when CC-CEDICT has its own (its gloss already shows otherwise).
            if !word.definitions.isEmpty, let source = word.addOnGlosses.first?.source {
                Text("\(source.components(separatedBy: " (").first ?? source): " + word.addOnGlosses.prefix(3).map(\.text).joined(separator: "; "))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack(spacing: 8) {
                Button { model.toggleSaved(word, sentence: sentence) } label: {
                    Label(isSaved ? "Saved" : "Save", systemImage: isSaved ? "star.fill" : "star")
                }
                .help(isSaved ? "Remove from Vocabulary (S)" : "Save to Vocabulary, with this sentence (S)")
                Button { Speech.speak(word.text) } label: { Label("Say", systemImage: "speaker.wave.2") }
                    .help("Say \(word.text) (Space)")
                Menu {
                    Button("Add to Terms…") { addingTerm = true }
                    Button("Copy \(word.text)") { Pasteboard.copy(word.text) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
                .popover(isPresented: $addingTerm) {
                    TermEditor(model: model, word: word) { addingTerm = false }
                }
                Spacer()
                Text("← → words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Sheet.background)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(word.text), \(word.pinyin)")
    }

    @ViewBuilder private func facts(encounters: Int) -> some View {
        let facts: [String] = [
            word.hskLevel.map { HSKTable.label(for: $0) },
            word.readingCorrected ? "context reading" : nil,
            word.alternativeReadings.isEmpty ? nil : "also " + word.alternativeReadings.prefix(3).joined(separator: ", "),
            encounters > 0 ? "seen \(encounters)× since saving" : nil,
            model.term(for: word.text).map { "Term: \($0.english)" },
        ].compactMap { $0 }
        if !facts.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                    if index > 0 { Text("·").foregroundStyle(.tertiary) }
                    Text(fact)
                        .foregroundStyle(fact == "context reading" ? Sheet.corrected : .secondary)
                }
            }
            .font(.callout)
            .lineLimit(1)
        }
    }
}

/// Pinyin with each syllable in its tone's colour.
private struct PinyinText: View {
    let syllables: [Syllable]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(syllables.enumerated()), id: \.offset) { index, syllable in
                Text((index > 0 ? " " : "") + syllable.text).foregroundStyle(ToneColor.color(syllable.tone))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Pinyin.display(syllables))
    }
}

// MARK: - Word breakdown

/// One word of the breakdown; click to show it in the word card.
private struct WordRow: View {
    let controller: ResultPanelController
    let word: Segment
    let isSaved: Bool
    let typeface: ReadingTypeface

    var body: some View {
        let isSelected = controller.selectedWordID == word.id
        Button {
            controller.selectedWordID = isSelected ? nil : word.id
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(word.text).font(ReadingFont.font(size: 19, typeface: typeface))
                    PinyinText(syllables: word.syllables).font(.system(size: 12, weight: .medium))
                }
                .frame(minWidth: 72, alignment: .leading)
                Text(word.gloss.isEmpty ? "—" : Gloss.clean(word.gloss))
                    .font(.callout)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if word.readingCorrected {
                        Image(systemName: "circle.dotted").foregroundStyle(Sheet.corrected).help("Context reading")
                    }
                    if let level = word.hskLevel {
                        Text(HSKTable.label(for: level)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if isSaved {
                        Image(systemName: "star.fill").foregroundStyle(Sheet.saved).help("In your Vocabulary")
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .help(word.definitions.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([word.text, word.pinyin, word.gloss, word.hskLevel.map { HSKTable.label(for: $0) } ?? "",
                             isSaved ? "in your Vocabulary" : ""].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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

/// The Translation: plain text on the sheet, right under the Reading it translates.
private struct TranslationText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.title3)
            .lineSpacing(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Translation: \(text)")
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct CopyButton: View {
    let text: String
    var label = "Copy"
    @ViewState private var copied = false

    var body: some View {
        Button {
            Pasteboard.copy(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .help("\(label) (⇧⌘C)")
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
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(status.map { $0.isReady ? message : $0.message } ?? message)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Sheet.corrected)
            }
            HStack(spacing: 6) {
                if let fix = status?.fix {
                    Button(model.title(for: fix)) { model.perform(fix) }
                        .buttonStyle(.borderedProminent)
                }
                Button("AI Settings…") { AppDelegate.shared?.showMainWindow(tab: .ai) }
            }
            .controlSize(.small)
            if !alternatives.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Or try with").font(.caption).foregroundStyle(.secondary)
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(alternatives) { config in
                            Button {
                                model.retry(session, with: config)
                            } label: {
                                Label(config.name, systemImage: config.isOnDevice ? "desktopcomputer" : "cloud")
                            }
                            .help(config.isOnDevice ? "Text stays on this Mac" : "Text is sent to \(config.name)")
                        }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Sheet.corrected.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .task { await model.refreshStatuses() }
    }
}

private struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct ProgressRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
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

/// Marks a child that sits right after the previous one with no gap (punctuation after a word).
struct GlueKey: LayoutValueKey {
    static let defaultValue = false
}

/// Lays children left-to-right, wrapping to new lines; a child marked with `LineBreakKey` forces a
/// break, and one marked with `GlueKey` stays on its predecessor's line with no gap.
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
            for (position, (index, size)) in zip(row.indices, row.sizes).enumerated() {
                if position > 0 { x += subviews[index][GlueKey.self] ? 0 : spacing }
                subviews[index].place(at: CGPoint(x: x, y: y + row.height - size.height), proposal: ProposedViewSize(size))
                x += size.width
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
            let glued = subview[GlueKey.self]
            let gap = glued ? 0 : spacing
            let current = rows[rows.count - 1]
            let needed = current.indices.isEmpty ? size.width : current.width + gap + size.width
            // Glued children (punctuation) never start a line on their own.
            if needed > width, !current.indices.isEmpty, !glued {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + gap + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            row.sizes.append(size)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty || rows.count == 1 }
    }
}
