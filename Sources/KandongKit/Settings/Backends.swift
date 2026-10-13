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

/// One AI endpoint the user can choose for Lookups.
public struct BackendConfig: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var type: BackendType
    /// For OpenAI-compatible Backends: what they were set up as.
    public var preset: OpenAIPreset?
    public var openAI: OpenAISettings?

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
