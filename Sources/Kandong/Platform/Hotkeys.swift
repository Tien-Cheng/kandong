import AppKit
import Carbon.HIToolbox
import OSLog

let hotkeyLog = Logger(subsystem: "com.tiencheng.kandong", category: "hotkeys")
import KandongKit

/// Global chord hotkeys (⌃⌥L etc.) via Carbon, each also registered with ⇧ added for the Local backend.
final class HotkeyCenter {
    typealias Handler = (HotkeyAction, _ local: Bool) -> Void

    private var handler: Handler
    private var refs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x4B44_4E47 // 'KDNG'

    init(handler: @escaping Handler) {
        self.handler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            Unmanaged<HotkeyCenter>.fromOpaque(context).takeUnretainedValue().fire(id.id)
            return noErr
        }, 1, &spec, context, &eventHandler)
    }

    deinit {
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func register(_ hotkeys: [HotkeyAction: KeyCombo]) {
        unregisterAll()
        for (index, action) in HotkeyAction.allCases.enumerated() {
            guard let combo = hotkeys[action] else { continue }
            add(combo, id: UInt32(index * 2))
            if !combo.shift { add(combo.withShift, id: UInt32(index * 2 + 1)) }
        }
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
    }

    private func add(_ combo: KeyCombo, id: UInt32) {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref) }
    }

    private func fire(_ id: UInt32) {
        let actions = HotkeyAction.allCases
        let index = Int(id / 2)
        guard index < actions.count else { return }
        handler(actions[index], id % 2 == 1)
    }
}

extension KeyCombo {
    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if command { flags |= UInt32(cmdKey) }
        if option { flags |= UInt32(optionKey) }
        if control { flags |= UInt32(controlKey) }
        if shift { flags |= UInt32(shiftKey) }
        return flags
    }

    init(event: NSEvent) {
        let flags = event.modifierFlags
        self.init(keyCode: UInt32(event.keyCode), command: flags.contains(.command), option: flags.contains(.option),
                  control: flags.contains(.control), shift: flags.contains(.shift))
    }

    /// "⌃⌥L"
    var displayString: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + KeyNames.name(for: keyCode)
    }
}

enum KeyNames {
    private static let names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
        50: "`", 51: "⌫", 53: "⎋", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    static func name(for keyCode: UInt32) -> String { names[keyCode] ?? "Key \(keyCode)" }
}

/// Watches modifier keys system-wide and fires on a lone tap of the chosen key (see `ModifierTapDetector`).
final class ModifierTapMonitor {
    private var monitors: [Any] = []
    private var detector = ModifierTapDetector(key: .off)
    private let onTap: (_ local: Bool) -> Void

    init(onTap: @escaping (_ local: Bool) -> Void) {
        self.onTap = onTap
    }

    var key: TapKey = .off {
        didSet {
            guard key != oldValue else { return }
            stop()
            detector = ModifierTapDetector(key: key)
            if key != .off { start() }
        }
    }

    private func start() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0); return $0 }) {
            monitors.append(local)
        }
    }

    private func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        detector = ModifierTapDetector(key: key)
    }

    private func handle(_ event: NSEvent) {
        let input: ModifierTapDetector.Input = event.type == .flagsChanged
            ? .modifiers(keyCode: event.keyCode, flags: UInt64(event.modifierFlags.rawValue), time: event.timestamp)
            : .other
        if let tap = detector.handle(input) {
            hotkeyLog.debug("\(self.key.displayName) tap (local: \(tap.local))")
            onTap(tap.local)
        }
    }
}
