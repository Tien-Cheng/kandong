import Foundation

/// A user-defined fixed rendering of a Chinese expression, used to steer Translation.
public struct Term: Hashable, Codable, Sendable, Identifiable {
    public var chinese: String
    public var english: String
    public var note: String

    public var id: String { chinese }

    public init(chinese: String, english: String, note: String = "") {
        self.chinese = chinese
        self.english = english
        self.note = note
    }
}

/// A word the user is learning, saved with the sentence it was found in.
public struct VocabularyItem: Hashable, Codable, Sendable, Identifiable {
    public var simplified: String
    public var traditional: String
    public var pinyin: String
    public var gloss: String
    public var sourceSentence: String
    public var addedAt: String

    public var id: String { simplified }

    public init(simplified: String, traditional: String, pinyin: String, gloss: String, sourceSentence: String, addedAt: Date = Date()) {
        self.simplified = simplified
        self.traditional = traditional
        self.pinyin = pinyin
        self.gloss = gloss
        self.sourceSentence = sourceSentence
        self.addedAt = Self.dateFormatter.string(from: addedAt)
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// The user-visible folder holding Context (`context.md`), Terms (`terms.csv`) and
/// Vocabulary (`vocabulary.csv`). Files are re-read whenever they change on disk, so edits
/// by the user or their agents apply to the next Lookup.
public final class Workspace: @unchecked Sendable {
    public let folder: URL
    public var contextURL: URL { folder.appendingPathComponent("context.md") }
    public var termsURL: URL { folder.appendingPathComponent("terms.csv") }
    public var vocabularyURL: URL { folder.appendingPathComponent("vocabulary.csv") }
    /// Add-on dictionaries (`AddOnDictionary`).
    public var dictionariesURL: URL { folder.appendingPathComponent(AddOnDictionary.folderName, isDirectory: true) }

    static let termsHeader = ["chinese", "english", "note"]
    static let vocabularyHeader = ["simplified", "traditional", "pinyin", "gloss", "source_sentence", "added_at"]

    private let lock = NSLock()
    private var cache: [URL: (modified: Date, text: String)] = [:]
    private var watcher: DispatchSourceFileSystemObject?

    public init(folder: URL) {
        self.folder = folder.standardizedFileURL
    }

    /// Expands "~" in a user-entered path.
    public convenience init(path: String) {
        self.init(folder: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
    }

    /// Creates the folder and starter files if missing. Never overwrites existing files.
    public func ensureExists() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let starters: [(URL, String)] = [
            (contextURL, Self.starterContext),
            (termsURL, CSV.write(header: Self.termsHeader, rows: [
                ["加油", "you've got this", "encouragement, not literally \"add oil\""],
                ["小明", "Xiaoming", "a name; keep it, don't translate it"],
            ])),
            (vocabularyURL, CSV.write(header: Self.vocabularyHeader, rows: [])),
        ]
        for (url, contents) in starters where !FileManager.default.fileExists(atPath: url.path) {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static let starterContext = """
    I'm an English speaker learning Chinese. I read messages from friends, social media posts, \
    articles and subtitles. Translate the way a native English speaker would say it, and keep \
    casual text casual.

    """

    // MARK: Reading

    private func read(_ url: URL) -> String {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[url], cached.modified == modified { return cached.text }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        cache[url] = (modified, text)
        return text
    }

    public func context() -> String {
        read(contextURL).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func terms() -> [Term] {
        CSV.records(read(termsURL)).compactMap { record in
            guard let chinese = record["chinese"], !chinese.isEmpty else { return nil }
            return Term(chinese: chinese, english: record["english"] ?? "", note: record["note"] ?? "")
        }
    }

    public func vocabulary() -> [VocabularyItem] {
        CSV.records(read(vocabularyURL)).compactMap { record in
            guard let simplified = record["simplified"], !simplified.isEmpty else { return nil }
            var item = VocabularyItem(
                simplified: simplified, traditional: record["traditional"] ?? "", pinyin: record["pinyin"] ?? "",
                gloss: record["gloss"] ?? "", sourceSentence: record["source_sentence"] ?? ""
            )
            item.addedAt = record["added_at"] ?? ""
            return item
        }
    }

    /// Terms whose Chinese (or, for English text, whose English) appears in `text`. Longest first.
    public func matchingTerms(in text: String) -> [Term] {
        let lowered = text.lowercased()
        return terms()
            .filter { term in
                text.contains(term.chinese)
                    || (!text.containsHan && !term.english.isEmpty && lowered.contains(term.english.lowercased()))
            }
            .sorted { $0.chinese.count > $1.chinese.count }
    }

    // MARK: Writing

    public func saveTerms(_ terms: [Term]) throws {
        let rows = terms.map { [$0.chinese, $0.english, $0.note] }
        try write(CSV.write(header: Self.termsHeader, rows: rows), to: termsURL)
    }

    /// Adds a Term, replacing any existing Term with the same Chinese.
    public func upsertTerm(_ term: Term) throws {
        var all = terms().filter { $0.chinese != term.chinese }
        all.append(term)
        try saveTerms(all)
    }

    public func saveVocabulary(_ items: [VocabularyItem]) throws {
        let rows = items.map { [$0.simplified, $0.traditional, $0.pinyin, $0.gloss, $0.sourceSentence, $0.addedAt] }
        try write(CSV.write(header: Self.vocabularyHeader, rows: rows), to: vocabularyURL)
    }

    public func addToVocabulary(_ item: VocabularyItem) throws {
        var all = vocabulary().filter { $0.simplified != item.simplified }
        all.append(item)
        try saveVocabulary(all)
    }

    public func removeFromVocabulary(_ simplified: String) throws {
        try saveVocabulary(vocabulary().filter { $0.simplified != simplified })
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        lock.lock()
        cache[url] = nil
        lock.unlock()
    }

    // MARK: Watching

    /// Calls `onChange` (on the main queue) whenever a file in the folder is added, removed or
    /// replaced. Editors and agents usually write atomically, which shows up as a folder change.
    public func watch(onChange: @escaping @Sendable () -> Void) {
        stopWatching()
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    public func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    deinit { watcher?.cancel() }
}
