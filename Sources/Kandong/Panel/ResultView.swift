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
            openAtLoginQuestion
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
                MarkdownText(markdown: Prompts.unfenced(Prompts.visibleText(session.explanation)), typeface: model.settings.readingTypeface)
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
        if model.settings.asksAboutLevel {
            QuestionCard {
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
        }
    }

    /// Asked once: Kandong's shortcuts only work while it's open.
    @ViewBuilder private var openAtLoginQuestion: some View {
        if model.asksAboutOpenAtLogin(in: session) {
            QuestionCard {
                Text("Open Kandong when you log in?").font(.callout.weight(.medium))
                HStack(spacing: 6) {
                    Button("Open at login") { model.answerOpenAtLogin(true) }
                    Button("Not now") { model.answerOpenAtLogin(false) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
                .controlSize(.small)
                if let error = model.loginItem.errorMessage {
                    Text(error).font(.caption).foregroundStyle(Sheet.corrected).textSelection(.enabled)
                }
                Text("You can change this in Settings → General.").font(.caption).foregroundStyle(.secondary)
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
            let saved = model.savedWords
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
