import Foundation

public enum BackendKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case codex
    case lmStudio
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .lmStudio: "LM Studio"
        case .custom: "OpenAI-compatible"
        }
    }

    /// Backends that run on this Mac and may be used as the Local backend.
    public static let localCandidates: [BackendKind] = [.lmStudio, .custom]
}

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
    public var defaultBackend: BackendKind = .codex
    public var localBackend: BackendKind = .lmStudio
    public var codex = CodexSettings()
    public var lmStudio = OpenAISettings(baseURL: "http://localhost:1234/v1")
    public var custom = OpenAISettings(baseURL: "http://localhost:11434/v1")

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

    public init() {}

    public func openAISettings(for kind: BackendKind) -> OpenAISettings? {
        switch kind {
        case .codex: nil
        case .lmStudio: lmStudio
        case .custom: custom
        }
    }

    // Decoding tolerates missing keys so settings survive app updates.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        defaultBackend = (try? c.decodeIfPresent(BackendKind.self, forKey: .defaultBackend)) ?? d.defaultBackend
        localBackend = (try? c.decodeIfPresent(BackendKind.self, forKey: .localBackend)) ?? d.localBackend
        codex = (try? c.decodeIfPresent(CodexSettings.self, forKey: .codex)) ?? d.codex
        lmStudio = (try? c.decodeIfPresent(OpenAISettings.self, forKey: .lmStudio)) ?? d.lmStudio
        custom = (try? c.decodeIfPresent(OpenAISettings.self, forKey: .custom)) ?? d.custom
        hotkeys = d.hotkeys.merging((try? c.decodeIfPresent([HotkeyAction: KeyCombo].self, forKey: .hotkeys)) ?? [:]) { $1 }
        tapKey = (try? c.decodeIfPresent(TapKey.self, forKey: .tapKey)) ?? d.tapKey
        myLevel = (try? c.decodeIfPresent(Int.self, forKey: .myLevel)) ?? d.myLevel
        pinyinForUnknownOnly = (try? c.decodeIfPresent(Bool.self, forKey: .pinyinForUnknownOnly)) ?? d.pinyinForUnknownOnly
        alwaysExplain = (try? c.decodeIfPresent(Bool.self, forKey: .alwaysExplain)) ?? d.alwaysExplain
        workspacePath = (try? c.decodeIfPresent(String.self, forKey: .workspacePath)) ?? d.workspacePath
        historyRetentionDays = (try? c.decodeIfPresent(Int.self, forKey: .historyRetentionDays)) ?? d.historyRetentionDays
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
