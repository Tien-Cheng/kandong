/// Where a recommended model's download into LM Studio has got.
enum ModelDownload: Equatable {
    case downloading(model: String, fraction: Double, detail: String)
    /// Downloaded; LM Studio is loading it into memory.
    case loading(model: String)
    case failed(model: String, message: String)

    var isActive: Bool {
        if case .failed = self { return false }
        return true
    }
}
