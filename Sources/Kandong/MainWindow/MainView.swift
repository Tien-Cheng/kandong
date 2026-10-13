import SwiftUI
import KandongKit

enum MainTab: String, Hashable, CaseIterable, Identifiable {
    case history, vocabulary, terms, ai, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: "History"
        case .vocabulary: "Vocabulary"
        case .terms: "Terms"
        case .ai: "AI"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .history: "clock"
        case .vocabulary: "star"
        case .terms: "character.book.closed"
        case .ai: "sparkles"
        case .settings: "gearshape"
        }
    }
}

@MainActor
@Observable
final class MainWindowState {
    var tab: MainTab = .history
    /// The Backend whose settings the AI section shows.
    var backendID = BackendConfig.appleIntelligence.id
}

struct MainView: View {
    let model: AppModel
    @Bindable var state: MainWindowState
    /// Names the window after the section shown.
    var setTitle: (String) -> Void = { _ in }

    var body: some View {
        NavigationSplitView {
            List(MainTab.allCases, selection: Binding(get: { state.tab }, set: { if let tab = $0 { state.tab = tab } })) { tab in
                Label(tab.title, systemImage: tab.icon).tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            Group {
                switch state.tab {
                case .history: HistoryView(model: model).padding(12)
                case .vocabulary: VocabularyView(model: model).padding(12)
                case .terms: TermsView(model: model).padding(12)
                case .ai: AIBackendsView(model: model, selectedID: $state.backendID)
                case .settings: SettingsView(model: model)
                }
            }
            .navigationTitle(state.tab.title)
        }
        .frame(minWidth: 760, minHeight: 520)
        .onChange(of: state.tab, initial: true) { setTitle(state.tab.title) }
    }
}

// MARK: - History

private struct HistoryView: View {
    let model: AppModel
    @ViewState private var search = ""
    @ViewState private var entries: [HistoryEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search history", text: $search).textFieldStyle(.roundedBorder)
                Button("Refresh", action: reload)
            }
            if entries.isEmpty {
                ContentUnavailableView("No lookups yet", systemImage: "text.magnifyingglass",
                                       description: Text(model.lookupHint))
            } else {
                List(entries) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: entry.source.symbolName).foregroundStyle(.secondary).frame(width: 18)
                            .help(entry.source.displayName)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.text.collapsingWhitespace).lineLimit(2).textSelection(.enabled)
                            if !entry.translation.isEmpty {
                                Text(entry.translation.collapsingWhitespace).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                            }
                            Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(entry.backend)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open") { model.reopen(entry) }
                            .controlSize(.small)
                            .help(entry.translation.isEmpty ? "Look it up again" : "Show this Result again, without asking the AI")
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Menu("Look up again with") {
                            ForEach(model.settings.backends) { config in
                                Button(config.name) { model.lookup(text: entry.text, source: .history, config: config) }
                            }
                        }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.text, forType: .string)
                        }
                        Button("Delete", role: .destructive) {
                            model.history.delete(id: entry.id)
                            reload()
                        }
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: search) { reload() }
        .onChange(of: model.session?.id) { reload() }
    }

    private func reload() {
        entries = model.history.recent(limit: 500, matching: search)
    }
}

// MARK: - Vocabulary

private struct VocabularyView: View {
    let model: AppModel
    @ViewState private var selection: Set<String> = []
    @ViewState private var search = ""

    var body: some View {
        let _ = model.workspaceRevision
        let all = model.workspace.vocabulary()
        // Diacritic-insensitive, so "hao" finds hǎo.
        let items = search.isEmpty ? all : all.filter { item in
            [item.simplified, item.traditional, item.pinyin, item.gloss].contains {
                $0.range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        let encounters = model.encounterCounts()
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search words, pinyin or meaning", text: $search).textFieldStyle(.roundedBorder)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.workspace.vocabularyURL]) }
            }
            Text("\(all.count) words in `vocabulary.csv` — import it into Anki with File → Import. Double-click a word to look up the sentence it came from.")
                .font(.callout).foregroundStyle(.secondary)
            Table(items, selection: $selection) {
                TableColumn("Word") { item in
                    VStack(alignment: .leading) {
                        Text(item.simplified).font(.title3)
                        if !item.traditional.isEmpty { Text(item.traditional).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .width(min: 60, ideal: 80)
                TableColumn("Pinyin", value: \.pinyin).width(min: 60, ideal: 90)
                TableColumn("Gloss") { Text($0.gloss).lineLimit(2).help($0.gloss) }
                TableColumn("Seen") { item in Text("\(encounters[item.simplified] ?? 0)×").foregroundStyle(.secondary) }
                    .width(40)
                TableColumn("Found in") { Text($0.sourceSentence).lineLimit(2).help($0.sourceSentence) }
                TableColumn("Added", value: \.addedAt).width(80)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Say") { ids.first.map(Speech.speak) }
                Button("Look Up Sentence") { lookUpSentence(of: ids.first, in: items) }
                Button("Remove from Vocabulary", role: .destructive) {
                    for id in ids { try? model.workspace.removeFromVocabulary(id) }
                    model.workspaceDidChange()
                }
            } primaryAction: { ids in
                lookUpSentence(of: ids.first, in: items)
            }
        }
    }
}

extension VocabularyView {
    private func lookUpSentence(of id: String?, in items: [VocabularyItem]) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        model.lookup(text: item.sourceSentence.isEmpty ? item.simplified : item.sourceSentence, source: .vocabulary, local: false)
    }
}

// MARK: - Terms

private struct TermsView: View {
    let model: AppModel
    @ViewState private var terms: [EditableTerm] = []
    @ViewState private var selection: Set<UUID> = []
    /// Edits not yet written; saved half a second after the last keystroke.
    @ViewState private var dirty = false
    @ViewState private var pendingSave: Task<Void, Never>?

    struct EditableTerm: Identifiable, Hashable {
        let id = UUID()
        var chinese: String
        var english: String
        var note: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Terms fix how expressions are translated — names, slang, set phrases. Changes save as you type to `terms.csv`, which you or an AI agent can also edit.")
                .font(.callout).foregroundStyle(.secondary)
            Table($terms, selection: $selection) {
                TableColumn("Chinese") { $term in TextField("中文", text: $term.chinese).onSubmit(save) }
                    .width(min: 80, ideal: 120)
                TableColumn("English") { $term in TextField("English", text: $term.english).onSubmit(save) }
                TableColumn("Note") { $term in TextField("Note", text: $term.note).onSubmit(save) }
            }
            .onChange(of: terms) { _, _ in scheduleSave() }
            HStack {
                Button { terms.append(EditableTerm(chinese: "", english: "", note: "")) } label: { Image(systemName: "plus") }
                Button {
                    terms.removeAll { selection.contains($0.id) }
                    save()
                } label: { Image(systemName: "minus") }
                .disabled(selection.isEmpty)
                Spacer()
                Button("Open in Editor") { NSWorkspace.shared.open(model.workspace.termsURL) }
                Button("Open context.md") { NSWorkspace.shared.open(model.workspace.contextURL) }
            }
        }
        .onAppear(perform: reload)
        // Only outside edits reload the table; our own save leaves the file matching it, so rows keep
        // their identity (and the field being typed in keeps focus).
        .onChange(of: model.workspaceRevision) { if !dirty && model.workspace.terms() != cleaned { reload() } }
        .onDisappear { if dirty { save() } }
    }

    private func reload() {
        terms = model.workspace.terms().map { EditableTerm(chinese: $0.chinese, english: $0.english, note: $0.note) }
        dirty = false
    }

    private var cleaned: [Term] {
        terms
            .map { Term(chinese: $0.chinese.trimmingCharacters(in: .whitespaces), english: $0.english.trimmingCharacters(in: .whitespaces), note: $0.note) }
            .filter { !$0.chinese.isEmpty }
    }

    /// Saves shortly after the last edit; a table that matches the file (e.g. just reloaded) isn't written.
    private func scheduleSave() {
        pendingSave?.cancel()
        guard cleaned != model.workspace.terms() else { return dirty = false }
        dirty = true
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        pendingSave?.cancel()
        try? model.workspace.saveTerms(cleaned)
        dirty = false
        model.workspaceDidChange()
    }
}
