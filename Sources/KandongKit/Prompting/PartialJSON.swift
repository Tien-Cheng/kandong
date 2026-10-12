import Foundation

/// Reads values out of JSON that is still being written.
public enum PartialJSON {
    /// The string value of the first `key` property so far, or nil if it hasn't started.
    /// `{"translation": "Chinese class at` gives "Chinese class at". Only object keys count: a
    /// string value that happens to equal `key` is skipped.
    public static func stringValue(of key: String, in text: String) -> String? {
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            guard characters[index] == "\"" else {
                index += 1
                continue
            }
            let (string, end, complete) = readString(characters, from: index + 1)
            guard complete else { return nil }
            index = end
            // Is this string a key, i.e. followed by a colon?
            var next = index
            while next < characters.count, characters[next].isWhitespace { next += 1 }
            guard next < characters.count, characters[next] == ":" else { continue }
            guard string == key else {
                index = next + 1
                continue
            }
            next += 1
            while next < characters.count, characters[next].isWhitespace { next += 1 }
            guard next < characters.count, characters[next] == "\"" else { return nil }
            return readString(characters, from: next + 1).value
        }
        return nil
    }

    /// Reads a JSON string body starting just after its opening quote: the text so far, the index
    /// after the closing quote, and whether the closing quote was reached. Stops before an escape
    /// that isn't complete or isn't valid.
    private static func readString(_ characters: [Character], from start: Int) -> (value: String, end: Int, complete: Bool) {
        var value = ""
        var index = start
        func hex(at offset: Int) -> UInt32? {
            guard offset + 4 <= characters.count else { return nil }
            return UInt32(String(characters[offset..<offset + 4]), radix: 16)
        }
        while index < characters.count {
            let character = characters[index]
            if character == "\"" { return (value, index + 1, true) }
            guard character == "\\" else {
                value.append(character)
                index += 1
                continue
            }
            guard index + 1 < characters.count else { break }
            switch characters[index + 1] {
            case "n": value.append("\n")
            case "t": value.append("\t")
            case "r": value.append("\r")
            case "b", "f": break
            case "u":
                guard let code = hex(at: index + 2) else { return (value, index, false) }
                if (0xD800..<0xDC00).contains(code) {
                    // A high surrogate needs a low one (\uDC00–\uDFFF) right after it.
                    guard index + 8 < characters.count, characters[index + 6] == "\\", characters[index + 7] == "u",
                          let low = hex(at: index + 8), (0xDC00..<0xE000).contains(low),
                          let scalar = Unicode.Scalar(0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00))
                    else { return (value, index, false) }
                    value.unicodeScalars.append(scalar)
                    index += 12
                    continue
                }
                guard let scalar = Unicode.Scalar(code) else { return (value, index, false) }
                value.unicodeScalars.append(scalar)
                index += 6
                continue
            case let escaped: value.append(escaped)
            }
            index += 2
        }
        return (value, index, false)
    }
}
