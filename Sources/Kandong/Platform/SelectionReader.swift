import AppKit
import ApplicationServices

/// The text the user has selected in the frontmost app, and where it is on screen.
struct CapturedSelection {
    var text: String
    /// Selection bounds in Cocoa screen coordinates (origin bottom-left), when the app reports them.
    var bounds: CGRect?
}

enum SelectionReader {
    /// Reads the selection through the Accessibility API, falling back to a simulated ⌘C
    /// (restoring the clipboard afterwards) for apps that don't expose it.
    @MainActor
    static func read() async -> CapturedSelection? {
        if let selection = readViaAccessibility(), !selection.text.isEmpty { return selection }
        guard let text = await readViaCopy(), !text.isEmpty else { return nil }
        return CapturedSelection(text: text, bounds: nil)
    }

    private static func readViaAccessibility() -> CapturedSelection? {
        let systemWide = AXUIElementCreateSystemWide()
        var appValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &appValue) == .success,
              let appValue, CFGetTypeID(appValue) == AXUIElementGetTypeID()
        else { return nil }
        let app = appValue as! AXUIElement
        // Chromium and Electron apps only build their accessibility tree when asked to.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return nil }
        let element = focusedValue as! AXUIElement

        var textValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &textValue) == .success,
              let text = textValue as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return CapturedSelection(text: text, bounds: selectionBounds(element))
    }

    private static func selectionBounds(_ element: AXUIElement) -> CGRect? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue
        else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsValue
        ) == .success, let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else { return nil }
        // AX uses top-left origin on the primary screen; Cocoa uses bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    @MainActor
    private static func readViaCopy() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = savePasteboard(pasteboard)
        let before = pasteboard.changeCount

        let source = CGEventSource(stateID: .privateState)
        let keyC: CGKeyCode = 8
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        var text: String?
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(25))
            if pasteboard.changeCount != before {
                text = pasteboard.string(forType: .string)
                break
            }
        }
        if pasteboard.changeCount != before { restorePasteboard(pasteboard, saved) }
        return text
    }

    private static func savePasteboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { data[type] = item.data(forType: type) }
            return data
        }
    }

    private static func restorePasteboard(_ pasteboard: NSPasteboard, _ saved: [[NSPasteboard.PasteboardType: Data]]) {
        pasteboard.clearContents()
        let items = saved.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
