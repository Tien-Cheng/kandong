import SwiftUI
import KandongKit

/// What the selected word means, docked at the bottom of the sheet, with what can be done with it.
struct WordCard: View {
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
struct PinyinText: View {
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
