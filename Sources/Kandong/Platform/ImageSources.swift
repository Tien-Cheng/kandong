import AppKit
import AVFoundation
import Vision

enum ScreenCapture {
    /// Lets the user drag out a screen region (like ⌘⇧4) and returns it as PNG, or nil if cancelled.
    static func captureRegion() async -> Data? {
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kandong-capture-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", url.path]
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume() }
        }
        return try? Data(contentsOf: url)
    }
}

enum ClipboardReader {
    enum Content {
        case image(Data)
        case text(String)
    }

    static func read() -> Content? {
        let pasteboard = NSPasteboard.general
        if let image = NSImage(pasteboard: pasteboard), let png = ImageData.png(from: image) {
            // Copied files also offer an icon image; prefer real text when there is some.
            if pasteboard.availableType(from: [.png, .tiff]) != nil || pasteboard.string(forType: .string) == nil {
                return .image(png)
            }
        }
        if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(text)
        }
        return nil
    }
}

enum ImageData {
    /// PNG data, downscaled so the longest side is at most `maxDimension` pixels.
    static func png(from image: NSImage, maxDimension: CGFloat = 2000) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxDimension / CGFloat(max(cg.width, cg.height)))
        let rep: NSBitmapImageRep
        if scale < 1, let context = CGContext(
            data: nil, width: Int(CGFloat(cg.width) * scale), height: Int(CGFloat(cg.height) * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            context.interpolationQuality = .high
            context.draw(cg, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
            guard let scaled = context.makeImage() else { return nil }
            rep = NSBitmapImageRep(cgImage: scaled)
        } else {
            rep = NSBitmapImageRep(cgImage: cg)
        }
        return rep.representation(using: .png, properties: [:])
    }

    static func normalized(_ data: Data) -> Data {
        guard let image = NSImage(data: data), let png = png(from: image) else { return data }
        return png
    }
}

/// On-device text recognition with Apple's Vision framework, used when the Backend can't read images.
enum OCR {
    static func recognize(_ png: Data) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(data: png).perform([request])
            let observations = (request.results ?? []).sorted { lhs, rhs in
                // Top-to-bottom, then left-to-right (Vision's origin is bottom-left).
                abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.01
                    ? lhs.boundingBox.midY > rhs.boundingBox.midY
                    : lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }
}

/// Reads Chinese aloud with the system's Mandarin voice.
@MainActor
enum Speech {
    private static let synthesizer = AVSpeechSynthesizer()

    static func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85
        synthesizer.speak(utterance)
    }

    static func stopIfNeeded() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }
}
