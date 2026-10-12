import SwiftUI
import KandongKit

enum MainTab: String, Hashable {
    case history, vocabulary, terms, settings
}

@MainActor
@Observable
final class MainWindowState {
    var tab: MainTab = .history
}

struct MainView: View {
    let model: AppModel
    @Bindable var state: MainWindowState

    var body: some View {
        TabView(selection: $state.tab) {
            HistoryView(model: model)
                .tabItem { Label("History", systemImage: "clock") }
                .tag(MainTab.history)
            VocabularyView(model: model)
                .tabItem { Label("Vocabulary", systemImage: "star") }
                .tag(MainTab.vocabulary)
            TermsView(model: model)
                .tabItem { Label("Terms", systemImage: "character.book.closed") }
                .tag(MainTab.terms)
            SettingsView(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(MainTab.settings)
        }
        .padding(12)
        .frame(minWidth: 720, minHeight: 500)
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
                                       description: Text("Highlight Chinese anywhere and tap right ⌘, or press ⌃⌥L."))
            } else {
                List(entries) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(entry.source)).foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.text).lineLimit(2).textSelection(.enabled)
                            if !entry.translation.isEmpty {
                                Text(entry.translation).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                            }
                            Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(entry.backend)")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Look up") { model.lookup(text: entry.text, source: entry.source, local: false) }
                            .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Look up with Local backend") { model.lookup(text: entry.text, source: entry.source, local: true) }
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

    private func icon(_ source: LookupSource) -> String {
        switch source {
        case .selection: "text.cursor"
        case .screenCapture: "camera.viewfinder"
        case .clipboard: "doc.on.clipboard"
        }
    }
}

// MARK: - Vocabulary

private struct VocabularyView: View {
    let model: AppModel
    @ViewState private var selection: Set<String> = []

    var body: some View {
        let _ = model.workspaceRevision
        let items = model.workspace.vocabulary()
        let encounters = model.encounterCounts()
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(items.count) words in `vocabulary.csv` — import it into Anki with File → Import.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.workspace.vocabularyURL]) }
            }
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
                Button("Remove from Vocabulary", role: .destructive) {
                    for id in ids { try? model.workspace.removeFromVocabulary(id) }
                    model.workspaceDidChange()
                }
            } primaryAction: { ids in
                ids.first.map(Speech.speak)
            }
        }
    }
}

// MARK: - Terms

private struct TermsView: View {
    let model: AppModel
    @ViewState private var terms: [EditableTerm] = []
    @ViewState private var selection: Set<UUID> = []
    @ViewState private var dirty = false

    struct EditableTerm: Identifiable, Hashable {
        let id = UUID()
        var chinese: String
        var english: String
        var note: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Terms fix how expressions are translated — names, slang, set phrases. They live in `terms.csv`, so you or an AI agent can edit it too.")
                .font(.callout).foregroundStyle(.secondary)
            Table($terms, selection: $selection) {
                TableColumn("Chinese") { $term in TextField("中文", text: $term.chinese).onSubmit(save) }
                    .width(min: 80, ideal: 120)
                TableColumn("English") { $term in TextField("English", text: $term.english).onSubmit(save) }
                TableColumn("Note") { $term in TextField("Note", text: $term.note).onSubmit(save) }
            }
            .onChange(of: terms) { dirty = true }
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
                Button("Save", action: save).keyboardShortcut("s").disabled(!dirty)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: model.workspaceRevision) { if !dirty { reload() } }
        .onDisappear { if dirty { save() } }
    }

    private func reload() {
        terms = model.workspace.terms().map { EditableTerm(chinese: $0.chinese, english: $0.english, note: $0.note) }
        dirty = false
    }

    private func save() {
        let cleaned = terms
            .map { Term(chinese: $0.chinese.trimmingCharacters(in: .whitespaces), english: $0.english.trimmingCharacters(in: .whitespaces), note: $0.note) }
            .filter { !$0.chinese.isEmpty }
        try? model.workspace.saveTerms(cleaned)
        dirty = false
        model.workspaceDidChange()
    }
}
