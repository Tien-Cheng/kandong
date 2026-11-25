import SwiftUI
import KandongKit

/// A long text in passages, each with its Translation beneath it. Only those near the viewport are
/// laid out.
struct PassagesView: View {
    let model: AppModel
    let controller: ResultPanelController
    let session: LookupSession

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(session.passages) { state in
                PassageRow(model: model, controller: controller, session: session, state: state)
                    .padding(.top, gap(above: state))
                    .id(state.id)
            }
        }
    }

    /// As the text has it: a blank line, or a new paragraph, starts apart; the lines of a chat or a
    /// verse, and a cut inside a paragraph, read on.
    private func gap(above state: PassageState) -> CGFloat {
        guard state.id > 0, let previous = session.passage(state.id - 1) else { return 0 }
        if state.passage.startsSection { return 24 }
        if isPlain(state), isPlain(previous) { return 4 }
        return state.passage.startsParagraph && !(state.passage.isLine && previous.passage.isLine) ? 24 : 14
    }

    private func isPlain(_ state: PassageState) -> Bool {
        session.direction == .learn && !state.needsTranslation
    }
}

private struct PassageRow: View {
    let model: AppModel
    let controller: ResultPanelController
    let session: LookupSession
    let state: PassageState

    var body: some View {
        let isLearn = session.direction == .learn
        // The Reading's own descent already sets what follows it apart.
        VStack(alignment: .leading, spacing: isLearn ? 4 : 8) {
            if !isLearn, !session.hidesSourcePassages, state.needsTranslation {
                Text(state.passage.text)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            reading
            if isLearn, let translation = state.translation, state.needsTranslation {
                TranslationText(text: translation)
            }
            progress
            if state.isExplained || state.explanationError != nil {
                PassageExplanation(model: model, session: session, state: state)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var reading: some View {
        let settings = model.settings
        if session.direction == .learn, !state.needsTranslation {
            // No Chinese to match: the size of the Translations, in the grey of text that isn't one.
            Text(state.passage.text)
                .font(.title3)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if !state.segments.isEmpty {
            let selected = controller.selectedWordID
            ReadingBlock(
                content: ReadingContent(
                    segments: state.segments, style: .passage, typeface: settings.readingTypeface, showTraditional: session.showTraditional,
                    withoutPinyin: settings.pinyinForUnknownOnly ? Set(state.segments.filter(model.isKnown).map(\.id)) : [],
                    saved: model.savedWords
                ),
                // Only the passage with the selected word is drawn again.
                selectedID: selected.flatMap { id in state.segments.contains { $0.id == id } ? id : nil },
                passage: state.id,
                actions: controller
            )
        } else if session.direction == .reverse, let chinese = state.translation {
            // Its Chinese as it comes in, until it's read.
            Text(chinese)
                .font(ReadingFont.font(size: ReadingStyle.passage.hanSize, typeface: settings.readingTypeface))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if session.direction == .reverse, !state.needsTranslation {
            Text(state.passage.text)
                .font(.title3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var progress: some View {
        if state.status == .translating, state.translation?.isEmpty ?? true {
            ProgressView().controlSize(.small)
        } else if state.status == .missing, session.status != .translating {
            HStack(spacing: 8) {
                Text("Not translated").foregroundStyle(Sheet.corrected)
                Button("Retry") { model.translateRest(of: session, only: state) }
                    .controlSize(.small)
            }
            .font(.callout)
        }
    }
}

/// Notes on one passage, under it.
private struct PassageExplanation: View {
    let model: AppModel
    let session: LookupSession
    let state: PassageState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.isExplained {
                if let other = session.explanationBackend, other.id != session.backendID {
                    SectionTitle("Explanation · \(other.name)")
                } else {
                    SectionTitle("Explanation")
                }
                MarkdownText(markdown: Prompts.unfenced(Prompts.visibleText(state.explanation)), typeface: model.settings.readingTypeface)
            }
            if state.isThinking {
                ProgressRow(text: "Thinking before it answers…")
            } else if state.isExplaining {
                ProgressView().controlSize(.small)
            }
            if let error = state.explanationError {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(error).font(.callout).foregroundStyle(Sheet.corrected).textSelection(.enabled)
                    Button("Retry") { model.explain(state, of: session) }
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 6)
    }
}

/// Long text's actions, always in sight under it, with how far the Translation has got.
struct ActionBar: View {
    let model: AppModel
    let controller: ResultPanelController
    let session: LookupSession

    var body: some View {
        HStack(spacing: 8) {
            PassageProgressLabel(model: model, session: session)
            Spacer(minLength: 4)
            if let text = session.translation, !text.isEmpty {
                if session.direction == .reverse {
                    CopyButton(text: text, label: "Copy Chinese")
                        .buttonStyle(.borderedProminent)
                } else {
                    CopyButton(text: text, label: "Copy translation")
                        .buttonStyle(.bordered)
                }
            }
            Menu {
                Button("Explain Passage") { controller.explain(session) }
                Button("Explain Whole Text") { model.explain(session) }
                    .disabled(session.isExplaining || !session.explanation.isEmpty)
            } label: {
                Label("Explain", systemImage: "graduationcap")
            } primaryAction: {
                controller.explain(session)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            .disabled(session.status == .translating)
            .help("Grammar and usage notes on this passage (E)")
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Sheet.background)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct PassageProgressLabel: View {
    let model: AppModel
    let session: LookupSession

    var body: some View {
        Group {
            switch session.status {
            case .readingImage:
                EmptyView()
            case .translating:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(translating)
                }
            case .done, .failed:
                let missing = session.untranslated.count
                if missing > 0 {
                    HStack(spacing: 8) {
                        Text("\(missing) not translated")
                        Button("Retry") { model.translateRest(of: session) }
                            .controlSize(.small)
                            .help("Translate the passages that are missing")
                    }
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
    }

    private var translating: String {
        let wanted = session.passages.filter(\.needsTranslation)
        let done = wanted.count { $0.status == .done }
        if session.isThinking { return "Thinking…" }
        return done >= wanted.count ? "Finishing…" : "Translating \(done + 1) of \(wanted.count)…"
    }
}
