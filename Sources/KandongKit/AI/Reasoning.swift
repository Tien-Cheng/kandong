import Foundation

/// What a request is for, so a Backend can think harder for some jobs than others.
public enum AITask: String, Codable, Sendable {
    /// Learn, Reverse and reading text in images: short, structured replies the user is waiting on.
    case translate
    case explain
}

/// How much a model thinks before it answers, per task. A level is one of `Reasoning.levels`, or ""
/// to leave it to the model.
public struct ReasoningSettings: Codable, Hashable, Sendable {
    public var translate: String
    public var explain: String

    public init(translate: String, explain: String) {
        self.translate = translate
        self.explain = explain
    }

    public subscript(task: AITask) -> String {
        get { task == .translate ? translate : explain }
        set { if task == .translate { translate = newValue } else { explain = newValue } }
    }

    /// Thinking makes small local models slow and sometimes stuck, so they translate without it.
    public static let local = ReasoningSettings(translate: "off", explain: "low")
    public static let modelDefault = ReasoningSettings(translate: "", explain: "")
}

public enum Reasoning {
    /// Levels from least to most thinking, as LM Studio lists them. "on" is a model's own thinking
    /// when it can only be switched on or off.
    public static let levels = ["off", "minimal", "low", "medium", "high", "xhigh", "on"]
    /// What any OpenAI-compatible server may accept.
    public static let openAILevels = ["off", "minimal", "low", "medium", "high"]

    public static func displayName(_ level: String) -> String {
        switch level {
        case "": "Model default"
        case "off": "Off"
        case "xhigh": "Extra high"
        default: level.capitalized
        }
    }

    /// The level to use when a model only offers `allowed`: the wanted one, else the most thinking
    /// it offers below it, else its least. "" keeps the model's default.
    public static func resolve(_ wanted: String, allowed: [String]) -> String {
        guard !wanted.isEmpty, !allowed.isEmpty, !allowed.contains(wanted) else { return wanted }
        let rank = { (level: String) in levels.firstIndex(of: level) ?? levels.count }
        let offered = allowed.sorted { rank($0) < rank($1) }
        return offered.last { rank($0) <= rank(wanted) } ?? offered[0]
    }

    /// The `reasoning_effort` to send for a level; nil to leave it out ("on" is the model's default).
    public static func effort(_ level: String) -> String? {
        switch level {
        case "", "on": nil
        case "off": "none"
        default: level
        }
    }
}

/// Spots a reply stuck repeating itself: its end is one short stretch of text over and over.
public struct RepetitionDetector: Sendable {
    /// The longest repeating stretch looked for, in characters.
    public var longestPeriod = 120
    /// How much text must be repetition before it counts.
    public var minimumSpan = 240

    public init() {}

    public func isRepeating(_ text: String) -> Bool {
        let tail = Array(text.suffix(max(minimumSpan, longestPeriod * 3)))
        guard tail.count >= minimumSpan else { return false }
        for period in 1...longestPeriod {
            // A stretch must come round at least three times, and fill the span.
            let span = max(minimumSpan, period * 3)
            guard span <= tail.count else { break }
            let start = tail.count - span
            if (start + period..<tail.count).allSatisfy({ tail[$0] == tail[$0 - period] }) { return true }
        }
        return false
    }
}
