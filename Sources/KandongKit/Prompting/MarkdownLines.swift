import Foundation

/// Splits a model's Markdown Explanation into simple blocks the panel can render line by line,
/// forgiving the sloppy syntax models sometimes stream ("-**word**", an unclosed "**").
public enum MarkdownLines {
    public enum Block: Equatable, Sendable {
        case blank
        case heading(String)
        case bullet(level: Int, text: String)
        case paragraph(String)
    }

    public static func parse(_ markdown: String) -> [Block] {
        markdown.components(separatedBy: .newlines).map(block)
    }

    static func block(_ raw: String) -> Block {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return .blank }
        if line.hasPrefix("#") {
            return .heading(balanced(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
        }
        let level = raw.prefix(while: { $0 == " " || $0 == "\t" }).count / 2
        for marker in ["- ", "* ", "+ ", "• ", "•"] where line.hasPrefix(marker) {
            return .bullet(level: level, text: balanced(String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)))
        }
        // "-**word**: …" — a bullet missing its space.
        if line.hasPrefix("-"), !line.hasPrefix("--"), line.dropFirst().first.map({ !$0.isNumber }) ?? false {
            return .bullet(level: level, text: balanced(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
        }
        return .paragraph(balanced(line))
    }

    /// Drops a dangling "**" so one unclosed marker doesn't print literally or bold the rest.
    static func balanced(_ text: String) -> String {
        guard text.components(separatedBy: "**").count % 2 == 0, let last = text.range(of: "**", options: .backwards) else { return text }
        var fixed = text
        fixed.removeSubrange(last)
        return fixed
    }
}
