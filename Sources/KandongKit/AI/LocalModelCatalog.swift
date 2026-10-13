import Foundation

/// A model Kandong recommends for LM Studio, from `models.json`.
public struct RecommendedModel: Codable, Hashable, Sendable, Identifiable {
    /// LM Studio's id, e.g. "google/gemma-4-e4b".
    public var id: String
    public var name: String
    /// The Hugging Face repo LM Studio opens when it can't download through its API.
    public var huggingFace: String
    /// The least memory a Mac needs for it to be recommended.
    public var minMemoryGB: Int
    public var downloadGB: Double
    public var vision: Bool
    public var note: String
}

/// The models Kandong recommends, by how much memory a Mac has. Kept in `models.json` at the top of
/// the repo so the list can change without a release; the app ships a copy for when it's offline.
/// Chosen with `KandongEval` (thinking off): Gemma 4 E4B matched Qwen 3.5 9B on every check at twice the
/// speed, and Qwen wrote some notes in Chinese. Gemma 4 12B, the same download size, writes the most
/// natural Chinese and gets the most 多音字 right, but takes twice as long and ~40s to Explain.
public struct LocalModelCatalog: Codable, Hashable, Sendable {
    public var version: Int
    public var models: [RecommendedModel]

    public static let remoteURL = URL(string: "https://raw.githubusercontent.com/Tien-Cheng/kandong/main/models.json")!

    /// Must match `models.json`; a test checks.
    public static let bundled = LocalModelCatalog(version: 1, models: [
        RecommendedModel(
            id: "google/gemma-4-e4b", name: "Gemma 4 E4B", huggingFace: "lmstudio-community/gemma-4-E4B-it-MLX-4bit",
            minMemoryGB: 16, downloadGB: 6.9, vision: true, note: "Fast and faithful; reads screenshots."
        ),
        RecommendedModel(
            id: "google/gemma-4-12b", name: "Gemma 4 12B", huggingFace: "lmstudio-community/gemma-4-12B-it-MLX-4bit",
            minMemoryGB: 32, downloadGB: 6.8, vision: true, note: "Most natural Chinese; reads screenshots."
        ),
    ])

    /// The latest list, or the bundled one when it can't be fetched or is from a newer format.
    public static func load() async -> LocalModelCatalog {
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let catalog = try? JSONDecoder().decode(LocalModelCatalog.self, from: data),
              catalog.version == bundled.version, !catalog.models.isEmpty
        else { return bundled }
        return catalog
    }

    /// The biggest model this Mac has the memory and disk for; nil when it has under the least any
    /// model needs, where Apple Intelligence is the better fit.
    public func recommendation(memoryBytes: UInt64, freeDiskBytes: Int64?) -> RecommendedModel? {
        let memoryGB = Double(memoryBytes) / 1_073_741_824
        return models
            .filter { Double($0.minMemoryGB) <= memoryGB.rounded() }
            .filter { model in freeDiskBytes.map { Double($0) / 1e9 >= model.downloadGB + 2 } ?? true }
            .max { $0.minMemoryGB < $1.minMemoryGB }
    }

    /// Recommendations for this Mac.
    public func recommendationForThisMac() -> RecommendedModel? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        return recommendation(memoryBytes: ProcessInfo.processInfo.physicalMemory, freeDiskBytes: free)
    }
}
