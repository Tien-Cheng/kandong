import AppKit
import CoreText
import SwiftUI
import KandongKit

/// Pleco-style tone colours, tuned per appearance so 12pt pinyin keeps 4.5:1 on the reading sheet,
/// and darker (or lighter) still with Increase Contrast.
enum ToneColor {
    static func color(_ tone: Int) -> Color {
        switch tone {
        case 1: tone1
        case 2: tone2
        case 3: tone3
        case 4: tone4
        default: neutral
        }
    }

    private static let tone1 = Color.adaptive(light: 0xD0312D, dark: 0xFF6961, lightHC: 0xA51D1A, darkHC: 0xFF9690)
    private static let tone2 = Color.adaptive(light: 0x1F7F3A, dark: 0x4CD472, lightHC: 0x135E28, darkHC: 0x7EE69A)
    private static let tone3 = Color.adaptive(light: 0x2160C8, dark: 0x6EA8FF, lightHC: 0x16459A, darkHC: 0xA1C6FF)
    private static let tone4 = Color.adaptive(light: 0x8340BF, dark: 0xC792FF, lightHC: 0x62268F, darkHC: 0xDDB8FF)
    private static let neutral = Color.adaptive(light: 0x737373, dark: 0xA3A3A3, lightHC: 0x545454, darkHC: 0xC8C8C8)
}

/// Colours of the reading sheet and the marks drawn on it.
enum Sheet {
    /// The solid surface the Reading sits on, inside the glass panel: a faintly warm paper in light,
    /// near-black in dark, so tone colours never depend on what's behind the panel.
    static let background = Color.adaptive(light: 0xFCFBF8, dark: 0x1C1C1E, lightHC: 0xFFFFFF, darkHC: 0x000000)
    /// A reading the AI changed for this context.
    static let corrected = Color.adaptive(light: 0xB35900, dark: 0xFFA94D, lightHC: 0x8A4400, darkHC: 0xFFC27F)
    /// A word in the Vocabulary.
    static let saved = Color.adaptive(light: 0xB08400, dark: 0xF2C94C, lightHC: 0x7A5C00, darkHC: 0xFFDB70)
}

extension Color {
    /// A colour that follows light/dark appearance and Increase Contrast.
    static func adaptive(light: UInt32, dark: UInt32, lightHC: UInt32, darkHC: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            switch match {
            case .darkAqua: return NSColor(hex: dark)
            case .accessibilityHighContrastAqua: return NSColor(hex: lightHC)
            case .accessibilityHighContrastDarkAqua: return NSColor(hex: darkHC)
            default: return NSColor(hex: light)
            }
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The Chinese in the Reading and the word card: LXGW WenKai (bundled, the face of Kandong's icon),
/// or PingFang when the user prefers it or the font file is missing.
enum ReadingFont {
    private static let fileName = "LXGWWenKaiLite-Regular.ttf"
    private static let postScriptName = "LXGWWenKaiLite-Regular"

    /// Registers the bundled font for this process; true if it's usable.
    @MainActor static let isAvailable: Bool = {
        let url = AppModel.dataDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            // Already registered is fine; anything else means the system face.
            return NSFont(name: postScriptName, size: 12) != nil
        }
        return true
    }()

    @MainActor static func font(size: CGFloat, typeface: ReadingTypeface) -> Font {
        typeface == .kai && isAvailable ? .custom(postScriptName, fixedSize: size) : .system(size: size)
    }
}

extension LookupSource {
    var symbolName: String {
        switch self {
        case .selection: "text.cursor"
        case .screenCapture: "camera.viewfinder"
        case .clipboard: "doc.on.clipboard"
        case .otherApp: "arrow.up.forward.app"
        case .history: "clock"
        case .vocabulary: "star"
        }
    }
}

extension String {
    /// Runs of whitespace and line breaks as single spaces, for one-line previews.
    var collapsingWhitespace: String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// CC-CEDICT senses tidied for reading: no classifier notes or numbered-pinyin cross-references.
/// "decision (CL:個|个[ge4])" → "decision"; "as in 他日[ta1 ri4]" → "as in 他日".
enum Gloss {
    static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"\s*\(?CL:[^);]*\)?"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[^\s|\[,;()]+\|([^\s|\[,;()]+)"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\[[A-Za-z]+[1-5](?:\s+[A-Za-z]+[1-5])*\]"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s*;\s*(?=;|$)"#, with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
    }
}
