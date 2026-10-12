import Foundation

/// Minimal RFC 4180 CSV: quoted fields, embedded commas, quotes and newlines.
public enum CSV {
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil

        func endField() { row.append(field); field = "" }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while let scalar = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if scalar == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.unicodeScalars.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                }
                continue
            }
            switch scalar {
            case "\"" where field.isEmpty: inQuotes = true
            case ",": endField()
            case "\r":
                if let next = iterator.next(), next != "\n" { pending = next }
                endRow()
            case "\n": endRow()
            default: field.unicodeScalars.append(scalar)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        // Strip a UTF-8 BOM some spreadsheet apps add.
        if let first = rows.first?.first, first.hasPrefix("\u{FEFF}") {
            rows[0][0] = String(first.dropFirst())
        }
        return rows
    }

    /// Rows as dictionaries keyed by the (lowercased, trimmed) header row.
    public static func records(_ text: String) -> [[String: String]] {
        let rows = parse(text)
        guard let header = rows.first else { return [] }
        let keys = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return rows.dropFirst().map { row in
            var record: [String: String] = [:]
            for (key, value) in zip(keys, row) { record[key] = value.trimmingCharacters(in: .whitespaces) }
            return record
        }
    }

    public static func write(header: [String], rows: [[String]]) -> String {
        ([header] + rows).map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
