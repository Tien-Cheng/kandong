import Foundation

/// An extra word list the user adds to CC-CEDICT, e.g. technical terms: a CC-CEDICT-format file in
/// the Workspace's `dictionaries` folder. Its header names it:
///
///     # name: Technical terms
///     # license: CC BY-NC 4.0 …
///     # source: https://glossary.eto.tech
///     # updated: 2026-10-13
public struct AddOnDictionary: Sendable, Identifiable {
    /// The file name without its extension.
    public var id: String
    public var name: String
    public var license: String
    public var source: String
    public var updated: String
    public var entryCount: Int
    public var url: URL
    /// The file's contents.
    public var text: String

    public static let folderName = "dictionaries"

    public init(url: URL, text: String) {
        id = url.deletingPathExtension().lastPathComponent
        self.url = url
        self.text = text
        var header: [String: String] = [:]
        var count = 0
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#") {
                let parts = line.dropFirst().split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    header[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
                }
            } else if !line.isEmpty {
                count += 1
            }
        }
        name = header["name"] ?? id
        license = header["license"] ?? ""
        source = header["source"] ?? ""
        updated = header["updated"] ?? ""
        entryCount = count
    }

    /// The add-on files in `folder` with their sizes and dates; it changes when one is added, edited or removed.
    public static func signature(of folder: URL) -> String {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files.filter { ["u8", "txt"].contains($0.pathExtension.lowercased()) }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return "\(url.lastPathComponent):\(values?.fileSize ?? 0):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.sorted().joined(separator: "|")
    }

    /// Every add-on in `folder` (`.u8` or `.txt` files), by name.
    public static func all(in folder: URL) -> [AddOnDictionary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { ["u8", "txt"].contains($0.pathExtension.lowercased()) }
            .compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).map { AddOnDictionary(url: url, text: $0) } }
            .sorted { $0.name < $1.name }
    }
}

/// The CSET-ETO Chinese Technical Glossary (Ben Murphy, https://glossary.eto.tech, CC BY-NC 4.0):
/// about 15,000 technical terms, many missing from CC-CEDICT. Downloaded by the user rather than
/// bundled, since its license doesn't allow commercial use (see ADR 0005).
public enum ETOGlossary {
    public static let id = "eto-technical-terms"
    public static let name = "Technical terms (CSET-ETO Chinese Technical Glossary)"
    public static let license = "CC BY-NC 4.0 (https://creativecommons.org/licenses/by-nc/4.0/). Ben Murphy, \"CSET-ETO Chinese Technical Glossary\", https://glossary.eto.tech. Converted to CC-CEDICT format by Kandong."
    public static let homepage = URL(string: "https://glossary.eto.tech")!
    /// The glossary's own published CSV export.
    public static let csvURL = URL(string: "https://docs.google.com/spreadsheets/d/e/2PACX-1vTO-PtXAf1aL98StTVimx_uzme-oX3FcZQuQVBiGiRI8cvh9l15Vk1cqKWy8Uu6RMGjxsnuTrGmgMJs/pub?output=csv")!

    /// Downloads the glossary and saves it as an add-on in `folder`. A download much smaller than the
    /// copy it would replace is refused, in case the sheet came back cut short.
    public static func download(into folder: URL, date: Date = Date()) async throws -> AddOnDictionary {
        var request = URLRequest(url: csvURL)
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BackendError.failed("Couldn't download the technical glossary (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let converted = convert(csv: String(decoding: data, as: UTF8.self), date: date)
        let url = folder.appendingPathComponent("\(id).u8")
        let previous = (try? String(contentsOf: url, encoding: .utf8)).map { AddOnDictionary(url: url, text: $0).entryCount } ?? 0
        guard converted.count > 1000, converted.count * 2 > previous else {
            throw BackendError.failed("The technical glossary download looks incomplete (\(converted.count) words); the copy you have is kept.")
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try converted.text.write(to: url, atomically: true, encoding: .utf8)
        return AddOnDictionary(url: url, text: converted.text)
    }

    /// The glossary's CSV as CC-CEDICT lines, with how many entries it has. Each term (and each
    /// abbreviation in its brackets) becomes an entry; terms that aren't all Chinese characters, or
    /// whose pinyin doesn't match them, are left out.
    public static func convert(csv: String, date: Date = Date()) -> (text: String, count: Int) {
        let rows = CSV.parse(csv)
        // A banner comes before the header row.
        guard let headerIndex = rows.firstIndex(where: { $0.first?.lowercased().hasPrefix("chinese term") == true }) else { return ("", 0) }
        // One entry per spelling and reading; a term listed twice with different senses (微管:
        // microtubule, and micropipe) keeps them all.
        var order: [String] = []
        var senses: [String: [String]] = [:]
        for row in rows[(headerIndex + 1)...] where row.count >= 4 {
            let english = row[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !english.isEmpty, !english.contains("Error retrieving definition") else { continue }
            let (terms, readings) = (split(row[0]), split(row[3], marker: "abbreviated:"))
            let definitions = Self.definitions(english)
            guard !definitions.isEmpty else { continue }
            for (term, reading) in zip(terms, readings) {
                guard let pinyin = numbered(reading, for: term) else { continue }
                let key = "\(term) \(term) [\(pinyin)]"
                if senses[key] == nil { order.append(key) }
                for definition in definitions where senses[key]?.contains(definition) != true {
                    senses[key, default: []].append(definition)
                }
            }
        }
        let lines = order.map { "\($0) /\(senses[$0]!.joined(separator: "/"))/" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let header = [
            "# name: \(name)",
            "# license: \(license)",
            "# source: \(homepage.absoluteString)",
            "# updated: \(formatter.string(from: date))",
        ]
        return ((header + lines).joined(separator: "\n") + "\n", lines.count)
    }

    /// "多模态 (多模)" → ["多模态", "多模"]; "duo1 mo2 tai4 (abbreviated: duo1 mo2)" → ["duo1 mo2 tai4", "duo1 mo2"].
    static func split(_ field: String, marker: String = "") -> [String] {
        let text = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards) else { return [text] }
        var inner = String(text[open.upperBound..<text.index(before: text.endIndex)])
        if !marker.isEmpty {
            guard inner.lowercased().hasPrefix(marker) else { return [text] }
            inner = String(inner.dropFirst(marker.count))
        }
        let main = String(text[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
        // Abbreviations are separated by semicolons, sometimes commas.
        return [main] + inner.split(whereSeparator: { ";,，、；".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// "Rock sugar. Alternatives: Crystal sugar, rock candy" → ["Rock sugar", "Crystal sugar", "rock candy"].
    static func definitions(_ english: String) -> [String] {
        var text = english
        if let abbreviated = text.range(of: "(abbreviated:") { text = String(text[..<abbreviated.lowerBound]) }
        var parts: [String] = []
        if let alternatives = text.range(of: "Alternatives:") {
            parts = [String(text[..<alternatives.lowerBound])]
                + text[alternatives.upperBound...].split(separator: ",").map(String.init)
        } else {
            parts = [text]
        }
        return parts
            // CC-CEDICT separates senses with "/", so a slash inside one becomes "or".
            .map { $0.replacingOccurrences(of: #"\s*/\s*"#, with: " or ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".;"))) }
            .filter { !$0.isEmpty }
    }

    /// The glossary's pinyin in CC-CEDICT's form ("lv4" → "lu:4", neutral "de0" → "de5"), or nil
    /// unless the term is all Chinese characters with one syllable each.
    static func numbered(_ reading: String, for term: String) -> String? {
        guard !term.isEmpty, term.allSatisfy(\.isHan) else { return nil }
        let syllables = reading.lowercased().split(separator: " ").map { syllable -> String in
            var s = String(syllable).replacingOccurrences(of: "v", with: "u:")
            if s.hasSuffix("0") { s = String(s.dropLast()) + "5" }
            return s
        }
        guard syllables.count == term.count, syllables.allSatisfy({ $0.last?.isNumber == true && $0.dropLast().allSatisfy { $0.isLetter || $0 == ":" } })
        else { return nil }
        return syllables.joined(separator: " ")
    }
}
