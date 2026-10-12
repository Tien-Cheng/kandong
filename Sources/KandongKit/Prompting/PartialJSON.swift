import Foundation

/// Reads values out of JSON that is still being written.
public enum PartialJSON {
    /// The string value of the first `key` property so far, or nil if it hasn't started.
    /// `{"translation": "Chinese class at` gives "Chinese class at".
    public static func stringValue(of key: String, in text: String) -> String? {
        guard let keyRange = text.range(of: "\"\(key)\"") else { return nil }
        var index = keyRange.upperBound
        func skipWhitespace() {
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
        }
        skipWhitespace()
        guard index < text.endIndex, text[index] == ":" else { return nil }
        index = text.index(after: index)
        skipWhitespace()
        guard index < text.endIndex, text[index] == "\"" else { return nil }
        index = text.index(after: index)

        var value = ""
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" { break }
            guard character == "\\" else {
                value.append(character)
                index = text.index(after: index)
                continue
            }
            // An escape: stop before one that isn't complete yet.
            let rest = text[text.index(after: index)...]
            guard let escaped = rest.first else { break }
            switch escaped {
            case "n": value.append("\n")
            case "t": value.append("\t")
            case "r": value.append("\r")
            case "b", "f": break
            case "u":
                let hex = rest.dropFirst().prefix(4)
                guard hex.count == 4, let code = UInt32(hex, radix: 16) else { return value }
                // A surrogate pair needs its second half too.
                if (0xD800..<0xDC00).contains(code) {
                    let low = rest.dropFirst(5)
                    guard low.hasPrefix("\\u"), low.count >= 6, let second = UInt32(low.dropFirst(2).prefix(4), radix: 16),
                          let scalar = Unicode.Scalar(0x10000 + ((code - 0xD800) << 10) + (second - 0xDC00)) else { return value }
                    value.unicodeScalars.append(scalar)
                    index = text.index(index, offsetBy: 12)
                    continue
                }
                if let scalar = Unicode.Scalar(code) { value.unicodeScalars.append(scalar) }
                index = text.index(index, offsetBy: 6)
                continue
            default: value.append(escaped)
            }
            index = text.index(index, offsetBy: 2)
        }
        return value
    }
}
