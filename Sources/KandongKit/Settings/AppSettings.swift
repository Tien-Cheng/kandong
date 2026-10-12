import Foundation

/// Whether an OpenAI-compatible model can read images.
public enum VisionSupport: String, Codable, CaseIterable, Sendable {
    case auto, yes, no
}

public struct CodexSettings: Codable, Hashable, Sendable {
    /// Path to the `codex` executable; empty means look it up.
    public var executablePath = ""
    /// Model id; empty means Codex's default model.
    public var model = ""
    public var effort = "low"

    public init() {}
}

public struct OpenAISettings: Codable, Hashable, Sendable {
    /// Base URL including the `/v1` suffix.
    public var baseURL: String
    /// Model id; empty means the first available model.
    public var model = ""
    public var vision: VisionSupport = .auto

    public init(baseURL: String) {
        self.baseURL = baseURL
    }
}

/// A key and modifiers, independent of AppKit/Carbon.
public struct KeyCombo: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var command = false
    public var option = false
    public var control = false
    public var shift = false

    public init(keyCode: UInt32, command: Bool = false, option: Bool = false, control: Bool = false, shift: Bool = false) {
        self.keyCode = keyCode
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
    }

    public var withShift: KeyCombo {
        var combo = self
        combo.shift = true
        return combo
    }
}

public enum HotkeyAction: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable, Identifiable {
    case lookupSelection
    case captureScreen
    case lookupClipboard

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .lookupSelection: "Look up selection"
        case .captureScreen: "Capture screen region"
        case .lookupClipboard: "Look up clipboard"
        }
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    /// Every Backend the user can choose, built-in ones first.
    public var backends: [BackendConfig] = AppSettings.defaultBackends
    public var defaultBackendID = BackendConfig.appleIntelligence.id
    /// Used when the user holds ⇧.
    public var localBackendID = BackendConfig.appleIntelligence.id
    public var codex = CodexSettings()

    public var hotkeys: [HotkeyAction: KeyCombo] = AppSettings.defaultHotkeys
    /// Modifier key that looks up the selection when tapped alone. Right ⌘ by default; right ⌥ is
    /// common for dictation tools.
    public var tapKey: TapKey = .rightCommand

    /// HSK band at or below which words count as known; 0 = off.
    public var myLevel = 0
    public var pinyinForUnknownOnly = false
    public var alwaysExplain = false
    public var workspacePath = "~/.config/kandong"
    public var historyRetentionDays = 90

    // Carbon virtual key codes: L = 37, S = 1, V = 9.
    public static let defaultHotkeys: [HotkeyAction: KeyCombo] = [
        .lookupSelection: KeyCombo(keyCode: 37, option: true, control: true),
        .captureScreen: KeyCombo(keyCode: 1, option: true, control: true),
        .lookupClipboard: KeyCombo(keyCode: 9, option: true, control: true),
    ]

    static let defaultBackends: [BackendConfig] = [.appleIntelligence, .codex, .openAI(.lmStudio, id: "lmstudio")]

    public init() {}

    public func backend(id: String) -> BackendConfig? {
        backends.first { $0.id == id }
    }

    /// The Backend for a Lookup: the Local one when ⇧ is held.
    public func backend(local: Bool) -> BackendConfig {
        backend(id: local ? localBackendID : defaultBackendID) ?? .appleIntelligence
    }

    /// Backends that keep text on this Mac, which may be the Local backend.
    public var localCandidates: [BackendConfig] {
        backends.filter(\.isOnDevice)
    }

    /// Removes a user-added Backend; if it was the Default or Local one, Apple Intelligence takes its place.
    public mutating func removeBackend(id: String) {
        guard let config = backend(id: id), !config.isBuiltIn else { return }
        backends.removeAll { $0.id == id }
        if defaultBackendID == id { defaultBackendID = BackendConfig.appleIntelligence.id }
        if localBackendID == id { localBackendID = BackendConfig.appleIntelligence.id }
    }

    enum CodingKeys: String, CodingKey {
        case backends, defaultBackendID, localBackendID, codex, hotkeys, tapKey, myLevel, pinyinForUnknownOnly
        case alwaysExplain, workspacePath, historyRetentionDays
    }

    /// Before Backends were a list there was one LM Studio and one custom endpoint, chosen by kind.
    private enum LegacyKeys: String, CodingKey {
        case defaultBackend, localBackend, lmStudio, custom
    }

    // Decoding tolerates missing keys so settings survive app updates.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        if let backends = try? c.decodeIfPresent([BackendConfig].self, forKey: .backends) {
            // Built-ins always exist, even if an edited settings file lost them.
            let missing = [BackendConfig.appleIntelligence, .codex].filter { builtIn in !backends.contains { $0.id == builtIn.id } }
            self.backends = missing + backends
            defaultBackendID = (try? c.decodeIfPresent(String.self, forKey: .defaultBackendID)) ?? d.defaultBackendID
            localBackendID = (try? c.decodeIfPresent(String.self, forKey: .localBackendID)) ?? d.localBackendID
        } else {
            try migrateLegacyBackends(from: decoder)
        }
        if backend(id: defaultBackendID) == nil { defaultBackendID = d.defaultBackendID }
        if backend(id: localBackendID)?.isOnDevice != true { localBackendID = d.localBackendID }
        codex = (try? c.decodeIfPresent(CodexSettings.self, forKey: .codex)) ?? d.codex
        hotkeys = d.hotkeys.merging((try? c.decodeIfPresent([HotkeyAction: KeyCombo].self, forKey: .hotkeys)) ?? [:]) { $1 }
        tapKey = (try? c.decodeIfPresent(TapKey.self, forKey: .tapKey)) ?? d.tapKey
        myLevel = (try? c.decodeIfPresent(Int.self, forKey: .myLevel)) ?? d.myLevel
        pinyinForUnknownOnly = (try? c.decodeIfPresent(Bool.self, forKey: .pinyinForUnknownOnly)) ?? d.pinyinForUnknownOnly
        alwaysExplain = (try? c.decodeIfPresent(Bool.self, forKey: .alwaysExplain)) ?? d.alwaysExplain
        workspacePath = (try? c.decodeIfPresent(String.self, forKey: .workspacePath)) ?? d.workspacePath
        historyRetentionDays = (try? c.decodeIfPresent(Int.self, forKey: .historyRetentionDays)) ?? d.historyRetentionDays
    }

    /// Turns the old fixed LM Studio and custom endpoints into Backends, keeping the user's choices.
    private mutating func migrateLegacyBackends(from decoder: Decoder) throws {
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        var lmStudio = BackendConfig.openAI(.lmStudio, id: "lmstudio")
        if let settings = try? legacy.decodeIfPresent(OpenAISettings.self, forKey: .lmStudio) { lmStudio.openAI = settings }
        backends = [.appleIntelligence, .codex, lmStudio]
        if let settings = try? legacy.decodeIfPresent(OpenAISettings.self, forKey: .custom) {
            let preset: OpenAIPreset = URL(string: settings.baseURL)?.port == 11434 ? .ollama : .other
            var custom = BackendConfig.openAI(preset, id: "custom")
            custom.openAI = settings
            backends.append(custom)
        }
        func id(forKind kind: String?) -> String? {
            switch kind {
            case "appleIntelligence": BackendConfig.appleIntelligence.id
            case "codex": BackendConfig.codex.id
            case "lmStudio": "lmstudio"
            case "custom": backend(id: "custom")?.id
            default: nil
            }
        }
        defaultBackendID = id(forKind: try? legacy.decodeIfPresent(String.self, forKey: .defaultBackend)) ?? BackendConfig.appleIntelligence.id
        localBackendID = id(forKind: try? legacy.decodeIfPresent(String.self, forKey: .localBackend)) ?? BackendConfig.appleIntelligence.id
    }
}

extension CodexSettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        executablePath = (try? c.decodeIfPresent(String.self, forKey: .executablePath)) ?? ""
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? ""
        effort = (try? c.decodeIfPresent(String.self, forKey: .effort)) ?? "low"
    }
}
