import Foundation

/// How Kandong talks to a Backend.
public enum BackendType: String, Codable, Sendable {
    case appleIntelligence
    case codex
    case openAICompatible
}

/// A starting point for an OpenAI-compatible Backend.
public enum OpenAIPreset: String, Codable, CaseIterable, Sendable, Identifiable {
    case lmStudio, ollama, openRouter, openAI, other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .lmStudio: "LM Studio"
        case .ollama: "Ollama"
        case .openRouter: "OpenRouter"
        case .openAI: "OpenAI"
        case .other: "Other OpenAI-compatible server"
        }
    }

    public var baseURL: String {
        switch self {
        case .lmStudio: "http://localhost:1234/v1"
        case .ollama: "http://localhost:11434/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .openAI: "https://api.openai.com/v1"
        case .other: "http://localhost:8080/v1"
        }
    }

    /// Hosted services need an API key; local servers don't.
    public var needsKey: Bool { self == .openRouter || self == .openAI }

    /// Small local models translate without thinking; hosted ones are left to decide.
    public var defaultReasoning: ReasoningSettings {
        switch self {
        case .lmStudio: .local
        case .ollama: ReasoningSettings(translate: "off", explain: "off")
        case .openRouter, .openAI, .other: .modelDefault
        }
    }
}

/// How a Backend may change the dictionary's readings (多音字) for the context.
public enum ReadingMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The dictionary's readings stand.
    case off
    /// For each word with more than one reading, the model picks one of the dictionary's.
    case choose
    /// The model names any reading it thinks is wrong and gives the right one.
    case free

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: "Off — keep the dictionary's"
        case .choose: "Choose among the dictionary's readings"
        case .free: "Correct freely"
        }
    }
}

/// One AI endpoint the user can choose for Lookups.
public struct BackendConfig: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var type: BackendType
    /// For OpenAI-compatible Backends: what they were set up as.
    public var preset: OpenAIPreset?
    public var openAI: OpenAISettings?
    /// The user's choice; nil follows `defaultReadingMode`, which may change with the Backend's URL or
    /// a later release.
    public var readingModeSetting: ReadingMode?

    public init(id: String, name: String, type: BackendType, preset: OpenAIPreset? = nil, openAI: OpenAISettings? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.preset = preset
        self.openAI = openAI
    }

    public static let appleIntelligence = BackendConfig(id: "apple-intelligence", name: "Apple Intelligence", type: .appleIntelligence)
    public static let codex = BackendConfig(id: "codex", name: "Codex", type: .codex)

    /// A new OpenAI-compatible Backend from a preset.
    public static func openAI(_ preset: OpenAIPreset, id: String = UUID().uuidString.lowercased(), name: String? = nil) -> BackendConfig {
        BackendConfig(id: id, name: name ?? preset.displayName, type: .openAICompatible, preset: preset,
                      openAI: OpenAISettings(baseURL: preset.baseURL))
    }

    /// Apple Intelligence and Codex are always there; the user adds and removes the rest.
    public var isBuiltIn: Bool { type != .openAICompatible }

    public var isLMStudio: Bool { preset == .lmStudio }

    /// How this Backend may change readings.
    public var readingMode: ReadingMode {
        get { readingModeSetting ?? defaultReadingMode }
        set { readingModeSetting = newValue }
    }

    /// From `KandongEval` (39 多音字 sentences, 12 the dictionary gets wrong): Apple Intelligence and
    /// Gemma 4 E4B fix none freely but 4 and 9 when choosing among the dictionary's readings; Codex
    /// fixes all 12 freely and 11 choosing (一行 has no right option). Small models on this Mac choose;
    /// large hosted ones correct freely.
    public var defaultReadingMode: ReadingMode {
        switch type {
        case .appleIntelligence: .choose
        case .codex: .free
        case .openAICompatible: isOnDevice ? .choose : .free
        }
    }

    /// How much an OpenAI-compatible Backend's model thinks per task.
    public var reasoning: ReasoningSettings {
        get { openAI?.reasoning ?? (preset ?? .other).defaultReasoning }
        set { openAI?.reasoning = newValue }
    }

    /// Where its API key is kept in the Keychain.
    public var keychainAccount: String { "api-key-\(id)" }

    /// Whether text sent to it stays on this Mac.
    public var isOnDevice: Bool {
        switch type {
        case .appleIntelligence: return true
        case .codex: return false
        case .openAICompatible:
            guard let host = openAI.flatMap({ URL(string: $0.baseURL) })?.host else { return false }
            return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        }
    }
}

/// Keychain accounts renamed when Backends became a list; moved once at launch.
public let legacyKeychainAccounts: [(from: String, to: String)] = [("custom-api-key", "api-key-custom")]

extension BackendConfig {
    private enum CodingKeys: String, CodingKey { case id, name, type, preset, openAI, readingModeSetting }

    // A reading mode this version doesn't know (from a newer one) falls back to the default rather
    // than losing the Backend.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(BackendType.self, forKey: .type)
        preset = try c.decodeIfPresent(OpenAIPreset.self, forKey: .preset)
        openAI = try c.decodeIfPresent(OpenAISettings.self, forKey: .openAI)
        readingModeSetting = (try? c.decodeIfPresent(String.self, forKey: .readingModeSetting)).flatMap { $0.flatMap(ReadingMode.init(rawValue:)) }
    }
}
