import Foundation

/// A modifier key that triggers a Lookup when tapped on its own.
public enum TapKey: String, Codable, CaseIterable, Sendable, Identifiable {
    case rightCommand
    case rightOption
    case rightControl
    case off

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .rightCommand: "Right ⌘"
        case .rightOption: "Right ⌥"
        case .rightControl: "Right ⌃"
        case .off: "Off"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .rightCommand: 54
        case .rightOption: 61
        case .rightControl: 62
        case .off: 0
        }
    }

    /// Device-specific flag bit set while this physical key is down (NX_DEVICER*KEYMASK).
    var deviceBit: UInt64 {
        switch self {
        case .rightCommand: 0x10
        case .rightOption: 0x40
        case .rightControl: 0x2000
        case .off: 0
        }
    }
}

/// Recognises a lone tap of a modifier key: pressed and released within `maxDuration` with nothing
/// else in between. Typing with the key held, holding it, or chords with other modifiers don't count.
/// ⇧ held at any point during the tap asks for the Local backend.
public struct ModifierTapDetector: Sendable {
    public enum Input: Sendable {
        /// A modifier key went down or up (`flagsChanged`); `flags` are the raw event flags.
        case modifiers(keyCode: UInt16, flags: UInt64, time: TimeInterval)
        /// Any other key or mouse button.
        case other
    }

    public struct Tap: Equatable, Sendable {
        public let local: Bool
    }

    static let shiftFlag: UInt64 = 0x20000
    static let modifierFlags: UInt64 = 0x40000 | 0x80000 | 0x100000 // ⌃ ⌥ ⌘

    public let key: TapKey
    public var maxDuration: TimeInterval = 0.3
    private var pressedAt: TimeInterval?
    private var interrupted = false
    private var shiftHeld = false
    private var keyDown = false

    public init(key: TapKey) {
        self.key = key
    }

    /// The ⌃/⌥/⌘ flag the tap key itself sets, which must not count as "another modifier".
    private var ownFlag: UInt64 {
        switch key {
        case .rightCommand: 0x100000
        case .rightOption: 0x80000
        case .rightControl: 0x40000
        case .off: 0
        }
    }

    /// Feeds one event; returns the Tap when the key is released after a clean tap.
    ///
    /// Press and release are read from the key's device-specific flag bit rather than the key code:
    /// synthetic events (System Events, remapping tools) often carry key code 0.
    public mutating func handle(_ input: Input) -> Tap? {
        guard key != .off else { return nil }
        guard case let .modifiers(_, flags, time) = input else {
            if pressedAt != nil { interrupted = true }
            return nil
        }
        let isDown = flags & key.deviceBit != 0
        defer { keyDown = isDown }
        if isDown && !keyDown {
            pressedAt = time
            interrupted = flags & Self.modifierFlags & ~ownFlag != 0
            shiftHeld = flags & Self.shiftFlag != 0
            return nil
        }
        if !isDown && keyDown {
            guard let start = pressedAt else { return nil }
            pressedAt = nil
            return !interrupted && time - start <= maxDuration ? Tap(local: shiftHeld) : nil
        }
        // Another modifier changed while the key is held: ⇧ selects the Local backend, anything else cancels.
        guard pressedAt != nil else { return nil }
        if flags & Self.modifierFlags & ~ownFlag != 0 {
            interrupted = true
        } else if flags & Self.shiftFlag != 0 {
            shiftHeld = true
        }
        return nil
    }
}
